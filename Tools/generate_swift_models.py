#!/usr/bin/env python3
"""Generate Swift Codable models from hermes-agent's gateway-contract.openrpc.json.

Usage: python3 generate_swift_models.py <openrpc.json> <output_dir>
Emits: SchemasNN.swift (chunked), Methods.swift, Notifications.swift, JSONValue.swift
"""
import json
import os
import re
import sys

SPEC_PATH, OUT_DIR = sys.argv[1], sys.argv[2]
spec = json.load(open(SPEC_PATH))
schemas = spec["components"]["schemas"]
methods = spec["methods"]
notifs = spec.get("x-notifications", [])

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
    "func", "import", "init", "inout", "internal", "let", "open", "operator",
    "private", "protocol", "public", "rethrows", "static", "struct",
    "subscript", "typealias", "var", "break", "case", "continue", "default",
    "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
    "repeat", "return", "switch", "where", "while", "as", "Any", "catch",
    "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true",
    "try", "some", "any",
}


def camel(name):
    parts = re.split(r"[_\-.]+", name)
    out = parts[0][:1].lower() + parts[0][1:]
    for p in parts[1:]:
        out += p[:1].upper() + p[1:]
    return out


def escape(name):
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def ref_name(ref):
    return ref.split("/")[-1]


def swift_type(sch):
    """Map a JSON-schema fragment to a Swift type string (optionality included)."""
    if sch is None or sch == {} or sch is True:
        return "JSONValue"
    if "$ref" in sch:
        return ref_name(sch["$ref"])
    if "anyOf" in sch:
        nonnull = [x for x in sch["anyOf"] if x.get("type") != "null"]
        if not nonnull:
            return "JSONValue?"
        if len(nonnull) > 1:  # true union -> untyped fallback
            return "JSONValue?"
        base = swift_type(nonnull[0])
        return base + ("?" if not base.endswith("?") else "")
    if sch.get("type") == "object":
        ap = sch.get("additionalProperties")
        if ap is True or ap == {}:
            return "[String: JSONValue]"
        if isinstance(ap, dict):
            return f"[String: {swift_type(ap).rstrip('?')}]"
        if "properties" in sch:
            return "JSONValue"  # anonymous nested object
        return "[String: JSONValue]"
    if sch.get("type") == "array":
        item = swift_type(sch.get("items"))
        return f"[{item}]"
    if sch.get("type") == "string":
        return "String"
    if sch.get("type") == "integer":
        return "Int"
    if sch.get("type") == "number":
        return "Double"
    if sch.get("type") == "boolean":
        return "Bool"
    return "JSONValue"


def gen_struct(name, sch):
    props = sch.get("properties", {})
    required = set(sch.get("required", []))
    lines = []
    desc = (sch.get("description") or "").strip().replace("\n", " ")
    if desc:
        lines.append("/// " + desc[:400])
    lines.append(f"struct {name}: Codable, Sendable {{")
    renames = []
    plain = []
    for pname, psch in props.items():
        cn = camel(pname)
        t = swift_type(psch)
        if pname not in required and not t.endswith("?"):
            t += "?"
        pd = (psch.get("description") or "").strip().replace("\n", " ")
        if pd:
            lines.append(f"    /// {pd[:200]}")
        lines.append(f"    var {escape(cn)}: {t}")
        if cn != pname:
            renames.append((cn, pname))
        else:
            plain.append(cn)
    if renames:
        lines.append("")
        lines.append("    enum CodingKeys: String, CodingKey {")
        for cn, pname in renames:
            lines.append(f'        case {escape(cn)} = "{pname}"')
        for cn in plain:
            lines.append(f"        case {escape(cn)}")
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines)


def gen_enum(name, sch):
    vals = sch["enum"]
    lines = [f"enum {name}: String, Codable, Sendable {{"]
    used = {}
    for v in vals:
        s = str(v)
        cn = camel(s)
        if not re.match(r"^[A-Za-z_]", cn):
            cn = "v" + cn
        if cn in SWIFT_KEYWORDS:
            cn += "Value"
        base = cn
        i = 2
        while cn in used:
            cn = f"{base}{i}"
            i += 1
        used[cn] = s
        lines.append(f'    case {escape(cn)} = "{s}"')
    lines.append("}")
    return "\n".join(lines)


os.makedirs(OUT_DIR, exist_ok=True)
generated, chunk, chunk_i = [], [], 0


def flush():
    global chunk, chunk_i
    if not chunk:
        return
    chunk_i += 1
    path = os.path.join(OUT_DIR, f"Schemas{chunk_i:02d}.swift")
    with open(path, "w") as f:
        f.write("// GENERATED from gateway-contract.openrpc.json -- do not edit.\n")
        f.write("import Foundation\n\n")
        f.write("\n\n".join(chunk) + "\n")
    chunk = []


for name in sorted(schemas):
    sch = schemas[name]
    chunk.append(gen_enum(name, sch) if "enum" in sch else gen_struct(name, sch))
    generated.append(name)
    if len(chunk) >= 60:
        flush()
flush()

JSONVALUE = """// GENERATED -- do not edit.
import Foundation

/// Untyped JSON value for schema positions the contract leaves open.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unhandled JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}
"""
with open(os.path.join(OUT_DIR, "JSONValue.swift"), "w") as f:
    f.write(JSONVALUE)


def schema_ref(m, key):
    entry = m.get(key)
    if isinstance(entry, list) and entry:
        sch = entry[0].get("schema", {})
        if "$ref" in sch:
            return ref_name(sch["$ref"])
    elif isinstance(entry, dict):
        sch = entry.get("schema", {})
        if "$ref" in sch:
            return ref_name(sch["$ref"])
    return None


m_lines = [
    "// GENERATED from gateway-contract.openrpc.json -- do not edit.",
    "import Foundation", "",
    "/// Wire names for every tui_gateway JSON-RPC method.",
    "enum GatewayMethod: String, Sendable, CaseIterable {",
]
for m in sorted(methods, key=lambda x: x["name"]):
    m_lines.append(f'    case {escape(camel(m["name"].replace(".", "_")))} = "{m["name"]}"')
m_lines.append("}")
m_lines += [
    "",
    "extension GatewayMethod {",
    "    /// Param/Result schema names per method (for typed dispatch).",
    "    static let registry: [GatewayMethod: (params: String?, result: String?)] = [",
]
for m in sorted(methods, key=lambda x: x["name"]):
    cn = escape(camel(m["name"].replace(".", "_")))
    p, r = schema_ref(m, "params"), schema_ref(m, "result")
    ps = f'"{p}"' if p else "nil"
    rs = f'"{r}"' if r else "nil"
    m_lines.append(f"        .{cn}: ({ps}, {rs}),")
m_lines += ["    ]", "}"]
with open(os.path.join(OUT_DIR, "Methods.swift"), "w") as f:
    f.write("\n".join(m_lines) + "\n")

n_lines = [
    "// GENERATED from gateway-contract.openrpc.json -- do not edit.",
    "import Foundation", "",
    "/// Server-to-client notifications carried on the tui_gateway WebSocket.",
    "enum ServerNotificationName: String, Sendable, CaseIterable {",
]
for n in sorted(notifs, key=lambda x: x["name"]):
    n_lines.append(f'    case {escape(camel(n["name"].replace(".", "_")))} = "{n["name"]}"')
n_lines.append("}")
n_lines += [
    "",
    "extension ServerNotificationName {",
    "    /// Payload schema name per notification, when the contract declares one.",
    "    static let payloads: [ServerNotificationName: String] = [",
]
for n in sorted(notifs, key=lambda x: x["name"]):
    cn = escape(camel(n["name"].replace(".", "_")))
    ref = None
    for p in n.get("params", []):
        sch = p.get("schema", {})
        if "$ref" in sch:
            ref = ref_name(sch["$ref"])
            break
    if ref:
        n_lines.append(f'        .{cn}: "{ref}",')
n_lines += ["    ]", "}"]
with open(os.path.join(OUT_DIR, "Notifications.swift"), "w") as f:
    f.write("\n".join(n_lines) + "\n")

print(f"generated {len(generated)} schemas, {len(methods)} methods, {len(notifs)} notifications")
print(f"output: {OUT_DIR}")
