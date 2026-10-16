#!/usr/bin/env python3
"""Generate Swift Codable models from gateway-contract.openrpc.json.

Reads the published tui_gateway OpenRPC contract and emits Swift types that
decode/encode the JSON-RPC params/results exactly as the server sends them.

Design choices (mirroring the plan's backward-compat discipline):
  - String enums -> "open enum" structs (typed constants + raw passthrough),
    so any value a newer/older backend sends still decodes.
  - `integer` -> Int64, `number` -> Double.
  - `anyOf` with one real type + null -> optional of that type.
  - `anyOf` with multiple real types / free-form {} -> JSONValue (open JSON).
  - Arrays/maps whose element/value is nullable or non-uniform -> [JSONValue] /
    [String: JSONValue], because synthesized Codable cannot decode [T?].
  - Properties absent from `required` become optional, or carry their schema
    default via decodeIfPresent ?? default when the default is a scalar.
"""
from __future__ import annotations
import json, re, sys
from pathlib import Path

CONTRACT = str(Path(__file__).resolve().parent.parent / "gateway-contract.openrpc.json")
OUT_DIR  = Path(__file__).resolve().parent.parent / "Sources" / "Generated"

SWIFT_KEYWORDS = {
    "associatedtype","class","deinit","enum","extension","fileprivate","func","import",
    "init","inout","internal","let","open","operator","private","precedencegroup","protocol",
    "public","rethrows","static","struct","subscript","typealias","var","break","case","catch",
    "continue","default","defer","do","else","fallthrough","for","guard","if","in","repeat",
    "return","throw","switch","where","while","as","Any","catch","false","is","nil","self",
    "Self","super","throws","true","try","_","some","any","actor","async","await","macro",
    "nonisolated","package","sendable","borrowing","consuming","distributed","dynamicMemberLookup",
    "indirect","infix","lazy","left","mutating","none","nonmutating","optional","override",
    "postfix","prefix","required","right","Type","unowned","weak","willSet","didSet","get","set",
    "convenience","final","required","retroactive","isolated","anyObject","Protocol",
}


def snake_to_camel(key: str) -> str:
    s = key.lstrip("_")
    parts = [p for p in s.split("_") if p != ""]
    if not parts:
        return key
    out = parts[0]
    for p in parts[1:]:
        out += p[:1].upper() + p[1:]
    return out


def swift_ident(name: str) -> str:
    ident = snake_to_camel(name)
    if ident in SWIFT_KEYWORDS:
        ident = "`" + ident + "`"
    return ident


def ref_name(ref: str) -> str:
    return ref.rsplit("/", 1)[-1]


def swift_literal(v, target_hint: str | None = None) -> str | None:
    """Render a Python JSON default as a Swift literal, or None if unsupported."""
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list):
        return "[]"
    if isinstance(v, dict):
        return "[:]"
    return None


class Generator:
    def __init__(self, spec: dict):
        self.spec = spec
        self.schemas = spec.get("components", {}).get("schemas", {})
        self.enum_names: set[str] = set()
        self.object_names: list[str] = []
        self.alias_names: list[str] = []
        self._resolve_cache: dict = {}
        for k, v in self.schemas.items():
            if v.get("type") == "string" and "enum" in v:
                self.enum_names.add(k)
            elif v.get("type") == "object" and v.get("properties"):
                self.object_names.append(k)
            else:
                self.alias_names.append(k)

    def swift_type(self, schema: dict, key: str | None = None) -> str:
        """Map a JSON Schema node to a Swift type string."""
        if "$ref" in schema:
            return ref_name(schema["$ref"])
        if "anyOf" in schema or "oneOf" in schema:
            variants = list(schema.get("anyOf") or schema.get("oneOf") or [])
            non_null = [v for v in variants if v.get("type") != "null"]
            has_null = len(non_null) < len(variants)
            if len(non_null) == 1:
                t = self.swift_type(non_null[0], key)
                return t + "?" if has_null and not t.endswith("?") else t
            # multiple real types, or empty {} => open JSON
            return "JSONValue" + ("?" if has_null else "")
        t = schema.get("type")
        if t == "string":
            if "enum" in schema:
                return "String"
            return "String"
        if t == "integer":
            return "Int64"
        if t == "number":
            return "Double"
        if t == "boolean":
            return "Bool"
        if t == "null":
            return "JSONValue"
        if t == "array":
            items = schema.get("items", {})
            # nullable or mixed element -> JSONValue
            if ("anyOf" in items or "oneOf" in items):
                variants = list(items.get("anyOf") or items.get("oneOf") or [])
                non_null = [v for v in variants if v.get("type") != "null"]
                if len(non_null) != 1:
                    return "[JSONValue]"
            return "[" + self.swift_type(items, key) + "]"
        if t == "object":
            return "JSONValue"
        # Unknown / free-form
        return "JSONValue"

    def uses_jsonvalue(self, ty: str) -> bool:
        return "JSONValue" in ty

    def generate_enum(self, name: str, schema: dict) -> list[str]:
        values = schema.get("enum", [])
        lines = []
        lines.append(f"/// Wire string for `{name}`. Open enum: typed constants plus")
        lines.append("/// raw passthrough so any backend value decodes without failing.")
        lines.append(f"public struct {name}: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {{")
        lines.append("    public let rawValue: String")
        lines.append("    public init(rawValue: String) { self.rawValue = rawValue }")
        lines.append("    public init(stringLiteral value: String) { self.init(rawValue: value) }")
        lines.append("    public init(from decoder: Decoder) throws {")
        lines.append("        let c = try decoder.singleValueContainer()")
        lines.append("        self.rawValue = try c.decode(String.self)")
        lines.append("    }")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append("        var c = encoder.singleValueContainer()")
        lines.append("        try c.encode(rawValue)")
        lines.append("    }")
        seen: dict[str, int] = {}
        for v in values:
            case = self._case_name(v)
            if case in seen:
                seen[case] += 1
                case = f"{case}{seen[case]}"
            else:
                seen[case] = 0
            literal = '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'
            lines.append(f"    public static let {case} = {name}(rawValue: {literal})")
        lines.append("}")
        lines.append("")
        return lines

    @staticmethod
    def _case_name(v: str) -> str:
        if not isinstance(v, str):
            v = str(v)
        s = re.sub(r"[^0-9A-Za-z_]", " ", v)
        parts = [p for p in s.split(" ") if p]
        if not parts:
            return "value"
        # preserve snake as camel after first segment
        base = re.sub(r"_+", "_", "_".join(parts))
        segs = [x for x in base.split("_") if x]
        out = segs[0]
        for x in segs[1:]:
            out += x[:1].upper() + x[1:]
        if out[0].isdigit():
            out = "_" + out
        if out in SWIFT_KEYWORDS:
            out += "_"
        return out

    def generate_struct(self, name: str, schema: dict) -> list[str]:
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        desc = schema.get("description", "")
        lines = []
        if desc:
            # first sentence only, wrapped
            first = re.split(r"[.!?]\s", desc.strip())[0].strip()
            lines.append("/// " + first.replace("\n", " "))
        lines.append(f"public struct {name}: Codable, Sendable {{")
        fields: list[tuple[str, str, bool, str | None]] = []  # (swiftName, type, isOptional, defaultLiteral|None)
        for key, pschema in props.items():
            ty = self.swift_type(pschema, key)
            is_optional = key not in required
            default_lit = None
            if is_optional:
                # try to bake the schema default in as a non-optional default
                dflt = pschema.get("default", None) if "default" in pschema else None
                has_default = "default" in pschema
                if has_default and self._default_literal(pschema, dflt) is not None:
                    default_lit = self._default_literal(pschema, dflt)
                    is_optional = False  # baked default keeps it non-optional
                elif ty.endswith("?"):
                    pass  # stays optional, no default
                else:
                    is_optional = True
            fields.append((swift_ident(key), ty, is_optional, default_lit))
        # emit property decls
        for sname, ty, is_opt, dflt in fields:
            if is_opt:
                ty = ty if ty.endswith("?") else ty + "?"
                lines.append(f"    public let {sname}: {ty}")
            elif dflt is not None:
                # non-optional, no stored default (assigned in init)
                base = ty.removesuffix("?")
                lines.append(f"    public let {sname}: {base}")
            else:
                lines.append(f"    public let {sname}: {ty}")
        # CodingKeys
        lines.append("    public enum CodingKeys: String, CodingKey {")
        for key in props.keys():
            lines.append(f"        case {swift_ident(key)} = {json.dumps(key)}")
        lines.append("    }")
        # custom init only if any optional or defaulted
        needs_init = any(f[2] or f[3] is not None for f in fields)
        if needs_init:
            lines.append("    public init(from decoder: Decoder) throws {")
            lines.append("        let c = try decoder.container(keyedBy: CodingKeys.self)")
            for sname, ty, is_opt, dflt in fields:
                base = ty.removesuffix("?")
                if is_opt:
                    lines.append(f"        self.{sname} = try c.decodeIfPresent({base}.self, forKey: .{sname})")
                elif dflt is not None:
                    lines.append(
                        f"        self.{sname} = (try? c.decodeIfPresent({base}.self, forKey: .{sname})) ?? {dflt}"
                    )
                else:
                    lines.append(f"        self.{sname} = try c.decode({base}.self, forKey: .{sname})")
            lines.append("    }")
        lines.append("}")
        lines.append("")
        return lines

    def _default_literal(self, pschema: dict, dflt) -> str | None:
        """Return Swift literal for a schema default, or None if it must stay optional."""
        if dflt is None:
            return None
        ty = self.swift_type(pschema, None).removesuffix("?")
        # A `$ref` to an open-enum struct: the default must be constructed via
        # `rawValue:` — the enum is a struct, not a Swift enum, so it has no
        # `.string(_:)` case. Emitting `.string(...)` here produced code that
        # did not compile against the matching `OpenEnums.swift` struct.
        if "$ref" in pschema and ref_name(pschema["$ref"]) in self.enum_names:
            if isinstance(dflt, str):
                lit = dflt.replace("\\", "\\\\").replace('"', '\\"')
                return f'{ref_name(pschema["$ref"])}(rawValue: "{lit}")'
            return None
        if ty == "JSONValue" or pschema.get("type") == "object":
            # JSON rules
            if isinstance(dflt, str):
                return ".string(\"" + dflt.replace("\\", "\\\\").replace('"', '\\"') + "\")"
            if isinstance(dflt, bool):
                return ".bool(true)" if dflt else ".bool(false)"
            if isinstance(dflt, int):
                return f".integer({dflt})"
            if isinstance(dflt, float):
                return f".number({dflt})"
            if isinstance(dflt, list):
                return ".array([])"
            if isinstance(dflt, dict):
                return ".object([:])"
            return None
        lit = swift_literal(dflt)
        if lit is None:
            return None
        if ty == "Double" and isinstance(dflt, int):
            return f"{dflt}.0"
        return lit

    def generate_alias(self, name: str, schema: dict) -> list[str]:
        ty = self.swift_type(schema, name)
        return [f"public typealias {name} = {ty}", ""]

    def run(self) -> str:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        enums, objects, aliases = [], [], []
        unresolved = []
        for k, v in self.schemas.items():
            if k in self.enum_names:
                enums.extend(self.generate_enum(k, v))
            elif k in self.object_names:
                objects.extend(self.generate_struct(k, v))
            else:
                aliases.extend(self.generate_alias(k, v))
        # --- support file JSONValue
        jsonvalue = JSON_VALUE_SRC
        # --- protocol catalog
        catalog = self.generate_catalog()
        (OUT_DIR / "JSONValue.swift").write_text(jsonvalue)
        (OUT_DIR / "OpenEnums.swift").write_text(
            HEADER + "\n".join(enums)
        )
        (OUT_DIR / "Models.swift").write_text(
            HEADER + "\n".join(objects)
        )
        (OUT_DIR / "Typealiases.swift").write_text(
            HEADER + ("\n".join(aliases) if aliases else "// (no non-object/non-enum schemas)\n")
        )
        (OUT_DIR / "ProtocolCatalog.swift").write_text(catalog)
        summary = (
            f"schemas={len(self.schemas)} enums={len(self.enum_names)} "
            f"objects={len(self.object_names)} aliases={len(self.alias_names)}"
        )
        return summary

    def generate_catalog(self) -> str:
        methods = self.spec.get("methods", [])
        notifs = self.spec.get("x-notifications", [])
        lines = [HEADER]
        lines.append("/// JSON-RPC method names (tui_gateway).")
        lines.append("public enum GWMethod {")
        for m in methods:
            n = m.get("name", "")
            const = self._const(n)
            lines.append(f"    public static let {const} = {json.dumps(n)}")
        lines.append("}")
        lines.append("")
        lines.append("/// Server->client notification names (tui_gateway).")
        lines.append("public enum GWNotification {")
        for n in notifs:
            name = n.get("name", "") if isinstance(n, dict) else str(n)
            lines.append(f"    public static let {self._const(name)} = {json.dumps(name)}")
        lines.append("}")
        lines.append("")
        return "\n".join(lines)

    @staticmethod
    def _const(name: str) -> str:
        out = re.sub(r"[^0-9A-Za-z_]", "_", name)
        out = out[:1].upper() + out[1:]
        # camel: keep dots->underscore, then just leave; ensure valid start
        if not re.match(r"[A-Za-z_]", out):
            out = "_" + out
        while "__" in out:
            out = out.replace("__", "_")
        if out in SWIFT_KEYWORDS:
            out += "_"
        return out


HEADER = """//
//  AUTO-GENERATED — DO NOT EDIT.
//  Generated by Scripts/gen_models.py from gateway-contract.openrpc.json.
//

import Foundation

"""

JSON_VALUE_SRC = """//
//  JSONValue.swift
//  Open JSON passthrough for free-form wire fields ({} , mixed anyOf, open maps).
//

import Foundation

/// A JSON value with full fidelity. Used where the wire contract allows
/// heterogeneous or unknown shapes the generated model cannot statically type.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .integer(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int64? {
        if case .integer(let i) = self { return i }
        if case .number(let d) = self { return Int64(d) }
        return nil
    }
    public var doubleValue: Double? {
        if case .number(let d) = self { return d }
        if case .integer(let i) = self { return Double(i) }
        return nil
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
}

"""


def main() -> str:
    spec = json.load(open(CONTRACT))
    g = Generator(spec)
    return g.run()


if __name__ == "__main__":
    print(main())