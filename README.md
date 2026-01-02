# sys-tools-mcp

A Ruby MCP (Model Context Protocol) server providing Claude Code-style tools for AI assistants. Includes 16 tools for file operations, shell commands, code search, LSP integration, and subagent orchestration.

## Requirements

- Ruby 3.x
- [mise](https://mise.jdx.dev/) (optional, for version management)
- AWS credentials configured (for subagent tasks via Bedrock)
- ripgrep (`rg`) for grep operations

### Ruby Gems

```bash
gem install anthropic connection_pool aws-sdk-bedrockruntime
```

## Configuration

Copy the example config and update the path:

```bash
cp mcp-config.json.example mcp-config.json
```

Edit `mcp-config.json` to point to your installation:

```json
{
  "mcpServers": {
    "sys-tools": {
      "command": "mise",
      "args": ["exec", "ruby", "--", "ruby", "/path/to/sys-tools-mcp.rb"]
    }
  }
}
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-1` | AWS region for Bedrock |
| `AWS_PROFILE` | `default` | AWS credentials profile |

## Tools

| Tool | Description |
|------|-------------|
| `Bash` | Execute shell commands (with timeout and background support) |
| `Read` | Read file contents with optional offset/limit |
| `Write` | Write/create files |
| `Edit` | String replacement in files |
| `Glob` | Find files by pattern |
| `Grep` | Search file contents with ripgrep |
| `Task` | Launch subagent for complex tasks (via Bedrock) |
| `TaskOutput` | Get output from background tasks |
| `TodoWrite` | Manage task list |
| `AskUserQuestion` | Interactive user input |
| `WebFetch` | Fetch URL content |
| `LSP` | Language Server Protocol operations |
| `KillShell` | Terminate background shells |
| `EnterPlanMode` | Start planning mode |
| `ExitPlanMode` | Exit planning mode |
| `Skill` | Execute slash command skills |

### LSP Support

Built-in LSP server detection for:
- Ruby (ruby-lsp)
- TypeScript/JavaScript (typescript-language-server)
- Python (pylsp)
- Go (gopls)
- Rust (rust-analyzer)

## Usage

Run directly:

```bash
ruby sys-tools-mcp.rb
```

Or via mise:

```bash
mise exec ruby -- ruby sys-tools-mcp.rb
```

The server communicates via stdin/stdout using JSON-RPC 2.0 (MCP protocol).

## Subagent Models

The `Task` tool supports these Bedrock models:

| Model | Bedrock ID |
|-------|------------|
| `sonnet` (default) | `us.anthropic.claude-sonnet-4-20250514-v1:0` |
| `opus` | `us.anthropic.claude-opus-4-20250514-v1:0` |
| `haiku` | `us.anthropic.claude-haiku-4-20250514-v1:0` |

## License

MIT
