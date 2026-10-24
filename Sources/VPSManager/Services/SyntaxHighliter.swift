import AppKit

// MARK: - Language definition

/// A lightweight, self-contained syntax "language" description. Rather than pull in an
/// external highlighting package (extra SPM dependency, extra risk), each language is
/// expressed as a small set of rules (keywords, comment/string syntax) that get compiled
/// into a single combined regular expression with named capture groups. That single regex
/// is then run once per highlight pass — much cheaper than running many separate regexes
/// over the same text.
struct CodeLanguage {
    let id: String
    fileprivate let mode: Mode

    fileprivate enum Mode {
        case generic(keywords: Set<String>, lineComment: String?, blockComment: (open: String, close: String)?, quotes: [Character], templateBacktick: Bool)
        case markdown
        case markup
        case css
        case diff
        case plain
    }

    var isPlainMode: Bool {
        if case .plain = mode { return true }
        return false
    }

    var usesAnchorsMatchLines: Bool {
        switch mode {
        case .markdown, .diff: return true
        default: return false
        }
    }

    /// The combined regex pattern for this language, or nil for plain text (no highlighting).
    var pattern: String? {
        switch mode {
        case .plain:
            return nil
        case .generic(let keywords, let lineComment, let blockComment, let quotes, let templateBacktick):
            return SyntaxHighlighter.buildGenericPattern(
                keywords: keywords, lineComment: lineComment, blockComment: blockComment,
                quotes: quotes, templateBacktick: templateBacktick
            )
        case .markdown:
            return SyntaxHighlighter.markdownPattern
        case .markup:
            return SyntaxHighlighter.markupPattern
        case .css:
            return SyntaxHighlighter.cssPattern
        case .diff:
            return SyntaxHighlighter.diffPattern
        }
    }
}

extension CodeLanguage: Equatable {
    static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool { lhs.id == rhs.id }
}

// MARK: - Language catalogue

extension CodeLanguage {
    static let plain = CodeLanguage(id: "plain", mode: .plain)

    static let javascript = CodeLanguage(id: "javascript", mode: .generic(
        keywords: Keywords.javascript, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\"", "'"], templateBacktick: true))

    static let typescript = CodeLanguage(id: "typescript", mode: .generic(
        keywords: Keywords.javascript.union(Keywords.typescriptExtra), lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\"", "'"], templateBacktick: true))

    static let python = CodeLanguage(id: "python", mode: .generic(
        keywords: Keywords.python, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let swift = CodeLanguage(id: "swift", mode: .generic(
        keywords: Keywords.swift, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let go = CodeLanguage(id: "go", mode: .generic(
        keywords: Keywords.go, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\"", "`"], templateBacktick: false))

    static let rust = CodeLanguage(id: "rust", mode: .generic(
        keywords: Keywords.rust, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let java = CodeLanguage(id: "java", mode: .generic(
        keywords: Keywords.java, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let kotlin = CodeLanguage(id: "kotlin", mode: .generic(
        keywords: Keywords.kotlin, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let c = CodeLanguage(id: "c", mode: .generic(
        keywords: Keywords.cFamily, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let cpp = CodeLanguage(id: "cpp", mode: .generic(
        keywords: Keywords.cFamily.union(Keywords.cppExtra), lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let csharp = CodeLanguage(id: "csharp", mode: .generic(
        keywords: Keywords.csharp, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let objc = CodeLanguage(id: "objc", mode: .generic(
        keywords: Keywords.cFamily.union(Keywords.objcExtra), lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let php = CodeLanguage(id: "php", mode: .generic(
        keywords: Keywords.php, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\"", "'"], templateBacktick: false))

    static let ruby = CodeLanguage(id: "ruby", mode: .generic(
        keywords: Keywords.ruby, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let shell = CodeLanguage(id: "shell", mode: .generic(
        keywords: Keywords.shell, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let sql = CodeLanguage(id: "sql", mode: .generic(
        keywords: Keywords.sql, lineComment: "--", blockComment: ("/*", "*/"),
        quotes: ["'"], templateBacktick: false))

    static let json = CodeLanguage(id: "json", mode: .generic(
        keywords: ["true", "false", "null"], lineComment: nil, blockComment: nil,
        quotes: ["\""], templateBacktick: false))

    static let yaml = CodeLanguage(id: "yaml", mode: .generic(
        keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let toml = CodeLanguage(id: "toml", mode: .generic(
        keywords: ["true", "false"], lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let ini = CodeLanguage(id: "ini", mode: .generic(
        keywords: ["true", "false"], lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let dockerfile = CodeLanguage(id: "dockerfile", mode: .generic(
        keywords: Keywords.dockerfile, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let makefile = CodeLanguage(id: "makefile", mode: .generic(
        keywords: ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "export", "unexport", "define", "endef", "override", "vpath"],
        lineComment: "#", blockComment: nil, quotes: ["\"", "'"], templateBacktick: false))

    static let lua = CodeLanguage(id: "lua", mode: .generic(
        keywords: Keywords.lua, lineComment: "--", blockComment: ("--[[", "]]"),
        quotes: ["\"", "'"], templateBacktick: false))

    static let perl = CodeLanguage(id: "perl", mode: .generic(
        keywords: Keywords.perl, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let r = CodeLanguage(id: "r", mode: .generic(
        keywords: Keywords.r, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let dart = CodeLanguage(id: "dart", mode: .generic(
        keywords: Keywords.dart, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\"", "'"], templateBacktick: true))

    static let scala = CodeLanguage(id: "scala", mode: .generic(
        keywords: Keywords.scala, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let markdown = CodeLanguage(id: "markdown", mode: .markdown)
    static let markup = CodeLanguage(id: "markup", mode: .markup)
    static let css = CodeLanguage(id: "css", mode: .css)
    static let diff = CodeLanguage(id: "diff", mode: .diff)

    static let hcl = CodeLanguage(id: "hcl", mode: .generic(
        keywords: Keywords.hcl, lineComment: "#", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let powershell = CodeLanguage(id: "powershell", mode: .generic(
        keywords: Keywords.powershell, lineComment: "#", blockComment: ("<#", "#>"),
        quotes: ["\"", "'"], templateBacktick: false))

    static let elixir = CodeLanguage(id: "elixir", mode: .generic(
        keywords: Keywords.elixir, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let erlang = CodeLanguage(id: "erlang", mode: .generic(
        keywords: Keywords.erlang, lineComment: "%", blockComment: nil,
        quotes: ["\""], templateBacktick: false))

    static let clojure = CodeLanguage(id: "clojure", mode: .generic(
        keywords: Keywords.clojure, lineComment: ";", blockComment: nil,
        quotes: ["\""], templateBacktick: false))

    static let haskell = CodeLanguage(id: "haskell", mode: .generic(
        keywords: Keywords.haskell, lineComment: "--", blockComment: ("{-", "-}"),
        quotes: ["\""], templateBacktick: false))

    static let vimscript = CodeLanguage(id: "vimscript", mode: .generic(
        keywords: Keywords.vimscript, lineComment: "\"", blockComment: nil,
        quotes: ["'"], templateBacktick: false))

    static let groovy = CodeLanguage(id: "groovy", mode: .generic(
        keywords: Keywords.groovy, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\"", "'"], templateBacktick: true))

    static let coffeescript = CodeLanguage(id: "coffeescript", mode: .generic(
        keywords: Keywords.coffeescript, lineComment: "#", blockComment: nil,
        quotes: ["\"", "'"], templateBacktick: false))

    static let elm = CodeLanguage(id: "elm", mode: .generic(
        keywords: Keywords.elm, lineComment: "--", blockComment: ("{-", "-}"),
        quotes: ["\""], templateBacktick: false))

    static let graphql = CodeLanguage(id: "graphql", mode: .generic(
        keywords: Keywords.graphql, lineComment: "#", blockComment: nil,
        quotes: ["\""], templateBacktick: false))

    static let protobuf = CodeLanguage(id: "protobuf", mode: .generic(
        keywords: Keywords.protobuf, lineComment: "//", blockComment: ("/*", "*/"),
        quotes: ["\""], templateBacktick: false))

    static let cmake = CodeLanguage(id: "cmake", mode: .generic(
        keywords: Keywords.cmake, lineComment: "#", blockComment: nil,
        quotes: ["\""], templateBacktick: false))

    static let zig = CodeLanguage(id: "zig", mode: .generic(
        keywords: Keywords.zig, lineComment: "//", blockComment: nil,
        quotes: ["\""], templateBacktick: false))

    static let nim = CodeLanguage(id: "nim", mode: .generic(
        keywords: Keywords.nim, lineComment: "#", blockComment: ("#[", "]#"),
        quotes: ["\""], templateBacktick: false))

    static let julia = CodeLanguage(id: "julia", mode: .generic(
        keywords: Keywords.julia, lineComment: "#", blockComment: ("#=", "=#"),
        quotes: ["\""], templateBacktick: false))

    static let fsharp = CodeLanguage(id: "fsharp", mode: .generic(
        keywords: Keywords.fsharp, lineComment: "//", blockComment: ("(*", "*)"),
        quotes: ["\""], templateBacktick: false))

    static let batch = CodeLanguage(id: "batch", mode: .generic(
        keywords: Keywords.batch, lineComment: "::", blockComment: nil,
        quotes: ["\""], templateBacktick: false))

    /// Resolves a language from a file extension (and, for extension-less files like
    /// `Dockerfile`/`Makefile`, the filename itself).
    static func forExtension(_ ext: String, filename: String) -> CodeLanguage? {
        let e = ext.lowercased()
        let f = filename.lowercased()

        if f == "dockerfile" || f.hasPrefix("dockerfile.") { return .dockerfile }
        if f == "makefile" || f == "gnumakefile" { return .makefile }
        if f == "cmakelists.txt" { return .cmake }

        // Filename-only matches for common extension-less config/build files and
        // shell dotfiles — these previously fell through to plain text (or, for
        // ones NSString.pathExtension can't see past the leading dot on, like
        // ".bashrc", couldn't even reach the extension switch below at all).
        switch f {
        case "vagrantfile", "rakefile", "gemfile", "guardfile", "berksfile", "brewfile", "capfile", "fastfile", "appfile", "matchfile", "podfile":
            return .ruby
        case "procfile", "caddyfile":
            return .plain
        case "crontab":
            return .shell
        case ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".profile", ".kshrc", ".xprofile":
            return .shell
        case ".vimrc", ".gvimrc":
            return .vimscript
        case ".gitconfig", ".npmrc", ".yarnrc", ".curlrc", ".wgetrc", ".hgrc", ".htaccess":
            return .ini
        case ".eslintrc", ".prettierrc", ".babelrc", ".stylelintrc":
            return .json
        default:
            break
        }

        switch e {
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "py", "pyw": return .python
        case "swift": return .swift
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return .cpp
        case "cs": return .csharp
        case "m", "mm": return .objc
        case "php": return .php
        case "rb": return .ruby
        case "sh", "bash", "zsh", "fish": return .shell
        case "sql": return .sql
        case "json", "jsonc", "webmanifest": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "ini", "cfg", "conf", "properties", "env": return .ini
        case "lua": return .lua
        case "pl", "pm": return .perl
        case "r": return .r
        case "dart": return .dart
        case "scala": return .scala
        case "md", "markdown": return .markdown
        case "html", "htm", "xhtml", "vue": return .markup
        case "xml", "svg", "plist": return .markup
        case "css": return .css
        case "scss", "less": return .css
        case "txt", "log", "gitignore", "gitattributes", "editorconfig", "csv", "tsv": return .plain
        case "diff", "patch": return .diff
        case "hcl", "tf", "tfvars": return .hcl
        case "ps1", "psm1", "psd1": return .powershell
        case "ex", "exs": return .elixir
        case "erl", "hrl": return .erlang
        case "clj", "cljs", "cljc", "edn": return .clojure
        case "hs", "lhs": return .haskell
        case "vim": return .vimscript
        case "groovy", "gradle": return .groovy
        case "coffee": return .coffeescript
        case "elm": return .elm
        case "graphql", "gql": return .graphql
        case "proto": return .protobuf
        case "cmake": return .cmake
        case "zig": return .zig
        case "nim", "nims": return .nim
        case "jl": return .julia
        case "fs", "fsx", "fsi": return .fsharp
        case "bat", "cmd": return .batch
        case "service", "socket", "timer", "target", "mount", "path", "netdev", "network", "link": return .ini
        default: return nil
        }
    }

    /// Extensions this app recognizes as text-ish (used to decide whether a large,
    /// unrecognized file is safe to try opening as text, versus treating it as opaque
    /// binary that should just offer a download).
    static let allExtensions: Set<String> = [
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "pyw", "swift", "go", "rs", "java", "kt", "kts",
        "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "cs", "m", "mm", "php", "rb", "sh", "bash", "zsh", "fish",
        "sql", "json", "jsonc", "webmanifest", "yml", "yaml", "toml", "ini", "cfg", "conf", "properties", "env",
        "lua", "pl", "pm", "r", "dart", "scala", "md", "markdown", "html", "htm", "xhtml", "vue", "xml", "svg", "plist",
        "css", "scss", "less", "txt", "log", "gitignore", "gitattributes", "editorconfig", "csv", "tsv",
        "diff", "patch", "hcl", "tf", "tfvars", "ps1", "psm1", "psd1", "ex", "exs", "erl", "hrl",
        "clj", "cljs", "cljc", "edn", "hs", "lhs", "vim", "groovy", "gradle", "coffee", "elm", "graphql", "gql",
        "proto", "cmake", "zig", "nim", "nims", "jl", "fs", "fsx", "fsi", "bat", "cmd",
        "service", "socket", "timer", "target", "mount", "path", "netdev", "network", "link"
    ]
}

// MARK: - Keyword sets

enum Keywords {
    static let javascript: Set<String> = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "async", "await", "static", "get", "set", "of", "null", "true", "false", "undefined"]
    static let typescriptExtra: Set<String> = ["interface", "type", "enum", "namespace", "declare", "implements", "private", "protected", "public", "readonly", "abstract", "as", "is", "keyof", "infer", "never", "unknown", "any", "string", "number", "boolean", "object", "symbol", "module"]
    static let python: Set<String> = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self", "cls"]
    static let swift: Set<String> = ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil", "self", "Self", "super", "throw", "throws", "true", "try", "await", "async"]
    static let go: Set<String> = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "true", "false", "nil", "iota"]
    static let rust: Set<String> = ["as", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "async", "await"]
    static let java: Set<String> = ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null", "var", "record", "sealed", "permits"]
    static let kotlin: Set<String> = ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while", "by", "catch", "constructor", "finally", "get", "import", "init", "set", "where", "abstract", "annotation", "companion", "const", "crossinline", "data", "enum", "external", "final", "infix", "inline", "inner", "internal", "lateinit", "noinline", "open", "operator", "out", "override", "private", "protected", "public", "reified", "sealed", "suspend", "tailrec", "vararg"]
    static let cFamily: Set<String> = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "include", "define", "ifdef", "ifndef", "endif", "pragma"]
    static let cppExtra: Set<String> = ["class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "friend", "new", "delete", "this", "try", "catch", "throw", "using", "operator", "explicit", "inline", "mutable", "nullptr", "true", "false", "bool", "constexpr", "decltype", "noexcept", "override", "final"]
    static let csharp: Set<String> = cFamily.union(["class", "namespace", "using", "public", "private", "protected", "internal", "static", "readonly", "virtual", "override", "abstract", "sealed", "new", "this", "base", "try", "catch", "finally", "throw", "true", "false", "null", "var", "string", "bool", "object", "interface", "enum", "struct", "get", "set", "async", "await", "yield", "is", "as", "typeof", "nameof"])
    static let objcExtra: Set<String> = ["interface", "implementation", "protocol", "property", "synthesize", "end", "nil", "self", "super", "YES", "NO", "id", "instancetype", "nonatomic", "strong", "weak", "copy", "readonly", "readwrite"]
    static let php: Set<String> = ["abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "endif", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "goto", "if", "implements", "include", "instanceof", "interface", "isset", "list", "match", "namespace", "new", "or", "print", "private", "protected", "public", "require", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor", "yield", "true", "false", "null", "this"]
    static let ruby: Set<String> = ["BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "attr_accessor", "attr_reader", "attr_writer", "require", "require_relative", "puts"]
    static let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "in", "return", "exit", "export", "local", "readonly", "shift", "break", "continue", "source", "alias", "unset", "eval", "exec", "trap", "echo", "printf", "test"]
    static let sql: Set<String> = ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "AND", "OR", "NOT", "NULL", "IS", "IN", "EXISTS", "BETWEEN", "LIKE", "AS", "DISTINCT", "UNION", "ALL", "CASE", "WHEN", "THEN", "END", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "CONSTRAINT", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION"]
    static let dockerfile: Set<String> = ["FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL"]
    static let lua: Set<String> = ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "self"]
    static let perl: Set<String> = ["my", "our", "local", "sub", "if", "elsif", "else", "unless", "while", "until", "for", "foreach", "do", "return", "use", "package", "require", "last", "next", "redo", "print", "defined", "undef"]
    static let r: Set<String> = ["if", "else", "repeat", "while", "function", "for", "next", "break", "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA", "in"]
    static let dart: Set<String> = ["abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends", "extension", "external", "factory", "false", "final", "finally", "for", "get", "hide", "if", "implements", "import", "in", "interface", "is", "late", "library", "mixin", "new", "null", "on", "operator", "part", "required", "rethrow", "return", "set", "show", "static", "super", "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "while", "with", "yield"]
    static let scala: Set<String> = ["abstract", "case", "catch", "class", "def", "do", "else", "extends", "false", "final", "finally", "for", "forSome", "if", "implicit", "import", "lazy", "match", "new", "null", "object", "override", "package", "private", "protected", "return", "sealed", "super", "this", "throw", "trait", "true", "try", "type", "val", "var", "while", "with", "yield"]
    static let hcl: Set<String> = ["resource", "provider", "variable", "output", "module", "data", "locals", "terraform", "for_each", "count", "depends_on", "provisioner", "lifecycle", "true", "false", "null"]
    static let powershell: Set<String> = ["begin", "break", "catch", "continue", "do", "else", "elseif", "end", "exit", "filter", "finally", "for", "foreach", "function", "if", "in", "param", "process", "return", "switch", "throw", "trap", "try", "until", "while", "true", "false", "null", "class", "enum"]
    static let elixir: Set<String> = ["def", "defp", "defmodule", "defmacro", "defstruct", "defprotocol", "defimpl", "do", "end", "if", "unless", "else", "case", "cond", "when", "fn", "true", "false", "nil", "import", "alias", "require", "use", "with", "for", "receive", "raise", "rescue", "after", "try", "catch"]
    static let erlang: Set<String> = ["module", "export", "import", "case", "of", "end", "if", "when", "receive", "after", "fun", "begin", "let", "andalso", "orelse", "true", "false", "try", "catch", "throw"]
    static let clojure: Set<String> = ["def", "defn", "defn-", "defmacro", "let", "if", "do", "fn", "loop", "recur", "when", "cond", "case", "ns", "require", "import", "true", "false", "nil", "quote", "try", "catch", "finally", "throw"]
    static let haskell: Set<String> = ["case", "class", "data", "default", "deriving", "do", "else", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where", "True", "False"]
    static let vimscript: Set<String> = ["function", "endfunction", "if", "else", "elseif", "endif", "while", "endwhile", "for", "endfor", "let", "call", "return", "set", "autocmd", "augroup", "command", "nnoremap", "inoremap", "vnoremap", "map", "unlet", "echo", "syntax", "highlight"]
    static let groovy: Set<String> = java.union(["def", "in", "as", "trait", "closure", "it"])
    static let coffeescript: Set<String> = ["class", "extends", "return", "if", "else", "unless", "for", "in", "of", "while", "until", "switch", "when", "then", "true", "false", "null", "yes", "no", "on", "off", "and", "or", "not", "is", "isnt", "new", "try", "catch", "finally", "throw"]
    static let elm: Set<String> = ["module", "import", "exposing", "type", "alias", "case", "of", "if", "then", "else", "let", "in", "as", "port", "True", "False"]
    static let graphql: Set<String> = ["query", "mutation", "subscription", "fragment", "type", "input", "enum", "interface", "union", "schema", "scalar", "directive", "extend", "implements", "on", "true", "false", "null"]
    static let protobuf: Set<String> = ["syntax", "package", "import", "option", "message", "enum", "service", "rpc", "returns", "repeated", "optional", "required", "reserved", "oneof", "map", "true", "false"]
    static let cmake: Set<String> = ["add_executable", "add_library", "add_subdirectory", "cmake_minimum_required", "project", "set", "if", "elseif", "else", "endif", "foreach", "endforeach", "while", "endwhile", "function", "endfunction", "macro", "endmacro", "target_link_libraries", "target_include_directories", "find_package", "include", "install", "option"]
    static let zig: Set<String> = ["const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "struct", "enum", "union", "error", "try", "catch", "defer", "errdefer", "comptime", "async", "await", "test", "import", "true", "false", "null", "undefined", "break", "continue"]
    static let nim: Set<String> = ["proc", "func", "method", "template", "macro", "let", "var", "const", "type", "object", "if", "elif", "else", "when", "case", "of", "for", "while", "return", "import", "export", "true", "false", "nil", "discard", "block", "try", "except", "finally", "raise"]
    static let julia: Set<String> = ["function", "end", "if", "elseif", "else", "for", "while", "return", "break", "continue", "struct", "mutable", "abstract", "type", "module", "import", "using", "export", "true", "false", "nothing", "try", "catch", "finally", "let", "do", "begin", "const", "global", "local"]
    static let fsharp: Set<String> = ["let", "rec", "in", "if", "then", "else", "elif", "match", "with", "type", "module", "open", "namespace", "fun", "function", "for", "while", "do", "try", "with", "finally", "true", "false", "null", "mutable", "member", "static", "abstract", "override"]
    static let batch: Set<String> = ["echo", "set", "if", "else", "goto", "call", "for", "in", "do", "exist", "not", "defined", "exit", "pause", "rem", "setlocal", "endlocal", "shift"]
}

// MARK: - Theme (VS Code "Dark+" inspired)

enum CodeTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let background = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
    static let gutterBackground = NSColor(calibratedRed: 0.117, green: 0.117, blue: 0.117, alpha: 1)
    static let plain = NSColor(calibratedRed: 0.831, green: 0.831, blue: 0.831, alpha: 1)
    static let lineNumber = NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.46, alpha: 1)

    /// Group names, roughly in the order they should be checked when a match spans
    /// multiple named groups (shouldn't normally happen, but keeps things deterministic).
    static let groupOrder = ["comment", "string", "attrstring", "number", "keyword", "atrule", "type", "tag", "function", "bold", "attrname", "property", "heading", "italic", "inlinecode", "link", "selector", "diffadd", "diffdel", "diffhunk", "diffmeta"]

    static func color(for group: String) -> NSColor {
        switch group {
        case "comment":
            return NSColor(calibratedRed: 0.42, green: 0.60, blue: 0.33, alpha: 1) // #6A9955
        case "string", "attrstring", "inlinecode":
            return NSColor(calibratedRed: 0.808, green: 0.569, blue: 0.471, alpha: 1) // #CE9178
        case "number", "italic":
            return NSColor(calibratedRed: 0.710, green: 0.808, blue: 0.659, alpha: 1) // #B5CEA8
        case "keyword", "atrule", "heading", "link":
            return NSColor(calibratedRed: 0.337, green: 0.612, blue: 0.839, alpha: 1) // #569CD6
        case "type", "tag":
            return NSColor(calibratedRed: 0.306, green: 0.788, blue: 0.690, alpha: 1) // #4EC9B0
        case "function", "bold":
            return NSColor(calibratedRed: 0.863, green: 0.863, blue: 0.667, alpha: 1) // #DCDCAA
        case "attrname", "property":
            return NSColor(calibratedRed: 0.612, green: 0.863, blue: 0.996, alpha: 1) // #9CDCFE
        case "selector":
            return NSColor(calibratedRed: 0.816, green: 0.816, blue: 0.416, alpha: 1) // #D0D08F-ish
        case "diffadd":
            return NSColor(calibratedRed: 0.596, green: 0.847, blue: 0.596, alpha: 1) // added lines, greenish
        case "diffdel":
            return NSColor(calibratedRed: 0.937, green: 0.518, blue: 0.518, alpha: 1) // removed lines, reddish
        case "diffhunk":
            return NSColor(calibratedRed: 0.337, green: 0.612, blue: 0.839, alpha: 1) // @@ hunk headers, blue
        case "diffmeta":
            return NSColor(calibratedRed: 0.863, green: 0.863, blue: 0.667, alpha: 1) // diff/index/---/+++ lines
        default:
            return plain
        }
    }
}

// MARK: - Highlighter

enum SyntaxHighlighter {
    private static var regexCache: [String: NSRegularExpression?] = [:]

    /// Re-colors the entire text storage according to `language`. Called on every
    /// character edit (see CodeEditorView's NSTextStorageDelegate hook) as well as
    /// once up front when a file is first loaded.
    static func highlight(_ textStorage: NSTextStorage, language: CodeLanguage) {
        let full = NSRange(location: 0, length: textStorage.length)
        guard full.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.removeAttribute(.foregroundColor, range: full)
        textStorage.addAttribute(.foregroundColor, value: CodeTheme.plain, range: full)
        textStorage.addAttribute(.font, value: CodeTheme.font, range: full)

        if let regex = regex(for: language) {
            let text = textStorage.string
            regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                for group in CodeTheme.groupOrder {
                    let r = match.range(withName: group)
                    if r.location != NSNotFound && r.length > 0 {
                        textStorage.addAttribute(.foregroundColor, value: CodeTheme.color(for: group), range: r)
                        break
                    }
                }
            }
        }
        textStorage.endEditing()
    }

    private static func regex(for language: CodeLanguage) -> NSRegularExpression? {
        if let cached = regexCache[language.id] { return cached }
        guard let pattern = language.pattern else {
            regexCache[language.id] = .some(nil)
            return nil
        }
        var options: NSRegularExpression.Options = []
        if language.usesAnchorsMatchLines { options.insert(.anchorsMatchLines) }
        let compiled = try? NSRegularExpression(pattern: pattern, options: options)
        regexCache[language.id] = compiled
        return compiled
    }

    // MARK: Pattern builders

    static func buildGenericPattern(
        keywords: Set<String>,
        lineComment: String?,
        blockComment: (open: String, close: String)?,
        quotes: [Character],
        templateBacktick: Bool
    ) -> String {
        var parts: [String] = []

        var commentAlternatives: [String] = []
        if let block = blockComment {
            commentAlternatives.append("\(NSRegularExpression.escapedPattern(for: block.open))[\\s\\S]*?\(NSRegularExpression.escapedPattern(for: block.close))")
        }
        if let line = lineComment {
            commentAlternatives.append("\(NSRegularExpression.escapedPattern(for: line)).*")
        }
        if !commentAlternatives.isEmpty {
            parts.append("(?<comment>\(commentAlternatives.joined(separator: "|")))")
        }

        var stringAlternatives: [String] = []
        for q in quotes {
            let qs = String(q)
            let escapedQ = NSRegularExpression.escapedPattern(for: qs)
            stringAlternatives.append("\(escapedQ)(?:\\\\.|[^\(escapedQ)\\\\])*\(escapedQ)")
        }
        if templateBacktick {
            stringAlternatives.append("`(?:\\\\.|[^`\\\\])*`")
        }
        if !stringAlternatives.isEmpty {
            parts.append("(?<string>\(stringAlternatives.joined(separator: "|")))")
        }

        parts.append("(?<number>\\b0[xX][0-9a-fA-F]+\\b|\\b\\d+\\.\\d+\\b|\\b\\d+\\b)")

        if !keywords.isEmpty {
            let escapedKeywords = keywords.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }
            parts.append("(?<keyword>\\b(?:\(escapedKeywords.joined(separator: "|")))\\b)")
        }

        parts.append("(?<type>\\b[A-Z][A-Za-z0-9_]*\\b)")
        parts.append("(?<function>\\b[A-Za-z_][A-Za-z0-9_]*(?=\\())")

        return parts.joined(separator: "|")
    }

    static let markdownPattern =
        "(?<heading>^#{1,6}[ \\t].*$)" +
        "|(?<inlinecode>`[^`]*`)" +
        "|(?<bold>\\*\\*[^*]+\\*\\*|__[^_]+__)" +
        "|(?<italic>\\*[^*]+\\*|_[^_]+_)" +
        "|(?<link>\\[[^\\]]*\\]\\([^)]*\\))" +
        "|(?<comment><!--[\\s\\S]*?-->)"

    static let markupPattern =
        "(?<comment><!--[\\s\\S]*?-->)" +
        "|(?<attrstring>\"[^\"]*\"|'[^']*')" +
        "|(?<tag></?[A-Za-z][A-Za-z0-9:_-]*)" +
        "|(?<attrname>\\b[a-zA-Z_:][A-Za-z0-9:_-]*(?=\\s*=))"

    static let diffPattern =
        "(?<diffhunk>^@@[^@]*@@.*$)" +
        "|(?<diffmeta>^(?:diff|index|Index|=+|old mode|new mode)\\b.*$|^---.*$|^\\+\\+\\+.*$)" +
        "|(?<diffadd>^\\+.*$)" +
        "|(?<diffdel>^-.*$)"

    static let cssPattern =
        "(?<comment>/\\*[\\s\\S]*?\\*/)" +
        "|(?<string>\"[^\"]*\"|'[^']*')" +
        "|(?<atrule>@[a-zA-Z-]+)" +
        "|(?<selector>[.#][a-zA-Z_-][A-Za-z0-9_-]*)" +
        "|(?<property>[a-zA-Z-]+(?=\\s*:))" +
        "|(?<number>-?\\b\\d+\\.?\\d*(?:px|em|rem|%|vh|vw|s|ms|deg)?\\b)"
}