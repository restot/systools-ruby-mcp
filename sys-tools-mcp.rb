#!/usr/bin/env ruby
# frozen_string_literal: true

# MCP Server - Full tool suite with minimal definitions
# 16 tools (all except NotebookEdit)

# Gems: gem install anthropic connection_pool aws-sdk-bedrockruntime
require "anthropic"
require "aws-sdk-bedrockruntime"

# Auth: Bedrock via AWS profile
BEDROCK_REGION = ENV.fetch("AWS_REGION", "us-east-1")
AWS_PROFILE = ENV.fetch("AWS_PROFILE", "default")

require "json"
require "openssl"
require "open3"
require "fileutils"
require "net/http"
require "uri"
require "timeout"

# State
$todos = []
$plan_mode = false
$background_tasks = {}
$background_shells = {}
$task_counter = 0

TOOLS = [
  {
    name: "Bash",
    description: "Execute shell command",
    inputSchema: {
      type: "object",
      properties: {
        command: {type: "string"},
        timeout: {type: "number"},
        run_in_background: {type: "boolean"}
      },
      required: ["command"]
    }
  },
  {
    name: "Read",
    description: "Read file contents",
    inputSchema: {
      type: "object",
      properties: {
        file_path: {type: "string"},
        offset: {type: "number"},
        limit: {type: "number"}
      },
      required: ["file_path"]
    }
  },
  {
    name: "Write",
    description: "Write file contents",
    inputSchema: {
      type: "object",
      properties: {
        file_path: {type: "string"},
        content: {type: "string"}
      },
      required: ["file_path", "content"]
    }
  },
  {
    name: "Edit",
    description: "Replace string in file",
    inputSchema: {
      type: "object",
      properties: {
        file_path: {type: "string"},
        old_string: {type: "string"},
        new_string: {type: "string"},
        replace_all: {type: "boolean"}
      },
      required: ["file_path", "old_string", "new_string"]
    }
  },
  {
    name: "Glob",
    description: "Find files by pattern",
    inputSchema: {
      type: "object",
      properties: {
        pattern: {type: "string"},
        path: {type: "string"}
      },
      required: ["pattern"]
    }
  },
  {
    name: "Grep",
    description: "Search file contents with ripgrep",
    inputSchema: {
      type: "object",
      properties: {
        pattern: {type: "string"},
        path: {type: "string"},
        glob: {type: "string"},
        type: {type: "string"},
        output_mode: {type: "string", enum: ["content", "files_with_matches", "count"]},
        "-i": {type: "boolean"},
        "-n": {type: "boolean"},
        "-A": {type: "number"},
        "-B": {type: "number"},
        "-C": {type: "number"}
      },
      required: ["pattern"]
    }
  },
  {
    name: "Task",
    description: "Launch subagent for complex task",
    inputSchema: {
      type: "object",
      properties: {
        prompt: {type: "string"},
        description: {type: "string"},
        subagent_type: {type: "string"},
        model: {type: "string", enum: ["sonnet", "opus", "haiku"]},
        run_in_background: {type: "boolean"}
      },
      required: ["prompt", "description", "subagent_type"]
    }
  },
  {
    name: "TaskOutput",
    description: "Get output from background task",
    inputSchema: {
      type: "object",
      properties: {
        task_id: {type: "string"},
        block: {type: "boolean"},
        timeout: {type: "number"}
      },
      required: ["task_id"]
    }
  },
  {
    name: "TodoWrite",
    description: "Manage task list",
    inputSchema: {
      type: "object",
      properties: {
        todos: {
          type: "array",
          items: {
            type: "object",
            properties: {
              content: {type: "string"},
              status: {type: "string", enum: ["pending", "in_progress", "completed"]},
              activeForm: {type: "string"}
            },
            required: ["content", "status", "activeForm"]
          }
        }
      },
      required: ["todos"]
    }
  },
  {
    name: "AskUserQuestion",
    description: "Ask user for input",
    inputSchema: {
      type: "object",
      properties: {
        questions: {
          type: "array",
          items: {
            type: "object",
            properties: {
              question: {type: "string"},
              header: {type: "string"},
              options: {type: "array"},
              multiSelect: {type: "boolean"}
            },
            required: ["question", "header", "options", "multiSelect"]
          }
        }
      },
      required: ["questions"]
    }
  },
  {
    name: "WebFetch",
    description: "Fetch URL content",
    inputSchema: {
      type: "object",
      properties: {
        url: {type: "string", format: "uri"},
        prompt: {type: "string"}
      },
      required: ["url", "prompt"]
    }
  },
  {
    name: "LSP",
    description: "Language server operations",
    inputSchema: {
      type: "object",
      properties: {
        operation: {type: "string", enum: ["goToDefinition", "findReferences", "hover", "documentSymbol", "workspaceSymbol", "goToImplementation", "prepareCallHierarchy", "incomingCalls", "outgoingCalls"]},
        filePath: {type: "string"},
        line: {type: "integer"},
        character: {type: "integer"}
      },
      required: ["operation", "filePath", "line", "character"]
    }
  },
  {
    name: "KillShell",
    description: "Kill background shell",
    inputSchema: {
      type: "object",
      properties: {
        shell_id: {type: "string"}
      },
      required: ["shell_id"]
    }
  },
  {
    name: "EnterPlanMode",
    description: "Start planning mode",
    inputSchema: {type: "object", properties: {}}
  },
  {
    name: "ExitPlanMode",
    description: "Finish planning mode",
    inputSchema: {type: "object", properties: {}}
  },
  {
    name: "Skill",
    description: "Execute slash command skill",
    inputSchema: {
      type: "object",
      properties: {
        skill: {type: "string"},
        args: {type: "string"}
      },
      required: ["skill"]
    }
  }
]

module ToolExecutor
  extend self

  def execute(name, args)
    send(name.downcase.to_sym, args)
  rescue NoMethodError
    {error: "Unknown tool: #{name}"}
  rescue => e
    {error: "#{e.class}: #{e.message}"}
  end

  def bash(args)
    cmd = args["command"]
    timeout_sec = args["timeout"] || 120

    if args["run_in_background"]
      $task_counter += 1
      id = "shell_#{$task_counter}"
      pid = spawn(cmd, [:out, :err] => "/tmp/#{id}.log")
      Process.detach(pid)
      $background_shells[id] = {pid: pid, cmd: cmd, started: Time.now}
      return "Background shell started: #{id} (pid: #{pid})"
    end

    output = ""
    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      begin
        Timeout.timeout(timeout_sec) do
          output = stdout.read + stderr.read
        end
      rescue Timeout::Error
        Process.kill("TERM", wait_thr.pid) rescue nil
        return {error: "Timeout after #{timeout_sec}s"}
      end
    end
    output.length > 30_000 ? output[0, 30_000] + "\n[truncated]" : output
  end

  def read(args)
    path = File.expand_path(args["file_path"])
    return {error: "Not found: #{path}"} unless File.exist?(path)

    lines = File.readlines(path)
    offset = args["offset"]&.to_i || 0
    limit = args["limit"]&.to_i || 2000

    selected = lines[offset, limit] || []
    selected.each_with_index.map { |line, i| "#{offset + i + 1}\t#{line}" }.join
  end

  def write(args)
    path = File.expand_path(args["file_path"])
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, args["content"])
    "Written: #{path}"
  end

  def edit(args)
    path = File.expand_path(args["file_path"])
    return {error: "Not found: #{path}"} unless File.exist?(path)

    content = File.read(path)
    old_str, new_str = args["old_string"], args["new_string"]

    count = content.scan(old_str).length
    return {error: "String not found"} if count == 0
    return {error: "Found #{count}x, use replace_all"} if count > 1 && !args["replace_all"]

    content = args["replace_all"] ? content.gsub(old_str, new_str) : content.sub(old_str, new_str)
    File.write(path, content)
    "Edited: #{path}"
  end

  def glob(args)
    base = args["path"] || Dir.pwd
    results = Dir.glob(File.join(base, args["pattern"]))
                 .sort_by { |f| File.file?(f) ? -File.mtime(f).to_i : 0 }
                 .take(200)
    results.empty? ? "No matches" : results.join("\n")
  end

  def grep(args)
    cmd = ["rg", args["pattern"]]
    cmd += ["--glob", args["glob"]] if args["glob"]
    cmd += ["--type", args["type"]] if args["type"]
    cmd += ["-i"] if args["-i"]
    cmd += ["-n"] if args["-n"] != false
    cmd += ["-A", args["-A"].to_s] if args["-A"]
    cmd += ["-B", args["-B"].to_s] if args["-B"]
    cmd += ["-C", args["-C"].to_s] if args["-C"]

    case args["output_mode"]
    when "files_with_matches", nil then cmd += ["-l"]
    when "count" then cmd += ["-c"]
    end

    cmd << (args["path"] || ".")
    stdout, stderr, _ = Open3.capture3(*cmd)
    output = stdout.empty? ? stderr : stdout
    output.length > 30_000 ? output[0, 30_000] + "\n[truncated]" : output
  end

  def task(args)
    # Bedrock model IDs
    model_map = {
      "sonnet" => "us.anthropic.claude-sonnet-4-20250514-v1:0",
      "opus" => "us.anthropic.claude-opus-4-20250514-v1:0",
      "haiku" => "us.anthropic.claude-haiku-4-20250514-v1:0"
    }
    model = model_map[args["model"]] || model_map["sonnet"]

    $task_counter += 1
    task_id = "task_#{$task_counter}"

    if args["run_in_background"]
      Thread.new do
        result = run_subagent(model, args["prompt"])
        $background_tasks[task_id] = {status: "completed", result: result}
      end
      $background_tasks[task_id] = {status: "running", started: Time.now}
      return "Task started: #{task_id}"
    end

    run_subagent(model, args["prompt"])
  end

  def run_subagent(model, prompt)
    client = Anthropic::BedrockClient.new(
      aws_region: BEDROCK_REGION,
      aws_profile: AWS_PROFILE
    )
    response = client.messages.create(
      model: model,
      max_tokens: 8192,
      messages: [{role: "user", content: prompt}]
    )
    response.content.map { |b| b.respond_to?(:text) ? b.text : b.to_s }.join("\n")
  rescue => e
    if e.message.include?("SSL") || e.message.include?("certificate")
      {error: <<~SSL_ERROR}
        SSL Certificate Error: #{e.message}

        This usually happens with Cloudflare Zero Trust WARP or corporate proxies doing SSL inspection.

        FIX: Install the Cloudflare root CA certificate:

          sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "/Library/Application Support/Cloudflare/installed_cert.pem"

        Or if you downloaded it manually:

          sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/certificate.crt

        Then restart Claude Code.
      SSL_ERROR
    else
      {error: "Subagent failed: #{e.message}"}
    end
  end

  def taskoutput(args)
    id = args["task_id"]
    task = $background_tasks[id]
    return {error: "Task not found: #{id}"} unless task

    if task[:status] == "running" && args["block"]
      timeout = args["timeout"] || 30_000
      deadline = Time.now + (timeout / 1000.0)
      sleep(0.1) while task[:status] == "running" && Time.now < deadline
    end

    task[:status] == "completed" ? task[:result] : "Status: #{task[:status]}"
  end

  def todowrite(args)
    $todos = args["todos"]
    lines = $todos.map do |t|
      icon = case t["status"]
             when "completed" then "[x]"
             when "in_progress" then "[>]"
             else "[ ]"
             end
      "#{icon} #{t["content"]}"
    end
    "Todos updated:\n#{lines.join("\n")}"
  end

  def askuserquestion(args)
    results = {}
    args["questions"].each_with_index do |q, i|
      STDERR.puts "\n#{q["header"]}: #{q["question"]}"
      q["options"].each_with_index { |opt, j| STDERR.puts "  #{j + 1}) #{opt["label"]}" }
      STDERR.print "Choice: "
      answer = STDIN.gets&.chomp
      results["q#{i}"] = answer
    end
    results.to_json
  end

  def webfetch(args)
    uri = URI.parse(args["url"])
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "sys-tools-mcp/1.0"
    response = http.request(request)

    case response
    when Net::HTTPRedirection
      "Redirect to: #{response["location"]}"
    when Net::HTTPSuccess
      body = response.body.force_encoding("UTF-8")
      # Strip HTML tags for basic text extraction
      text = body.gsub(/<script[^>]*>.*?<\/script>/mi, "")
                 .gsub(/<style[^>]*>.*?<\/style>/mi, "")
                 .gsub(/<[^>]+>/, " ")
                 .gsub(/\s+/, " ")
                 .strip
      text.length > 20_000 ? text[0, 20_000] + "\n[truncated]" : text
    else
      {error: "HTTP #{response.code}: #{response.message}"}
    end
  rescue => e
    {error: "Fetch failed: #{e.message}"}
  end

  def lsp(args)
    file_path = File.expand_path(args["filePath"])
    line = args["line"] - 1  # LSP is 0-indexed
    char = args["character"] - 1
    operation = args["operation"]

    ext = File.extname(file_path)
    server_cmd = case ext
                 when ".rb" then ["ruby-lsp"]
                 when ".ts", ".tsx", ".js", ".jsx" then ["typescript-language-server", "--stdio"]
                 when ".py" then ["pylsp"]
                 when ".go" then ["gopls"]
                 when ".rs" then ["rust-analyzer"]
                 else return {error: "No LSP server configured for #{ext}"}
                 end

    lsp_method = case operation
                 when "goToDefinition" then "textDocument/definition"
                 when "findReferences" then "textDocument/references"
                 when "hover" then "textDocument/hover"
                 when "documentSymbol" then "textDocument/documentSymbol"
                 when "workspaceSymbol" then "workspace/symbol"
                 when "goToImplementation" then "textDocument/implementation"
                 else return {error: "Unsupported operation: #{operation}"}
                 end

    uri = "file://#{file_path}"
    content = File.read(file_path)

    Open3.popen3(*server_cmd) do |stdin, stdout, stderr, wait_thr|
      # Initialize
      send_lsp(stdin, 1, "initialize", {
        processId: Process.pid,
        rootUri: "file://#{Dir.pwd}",
        capabilities: {}
      })
      read_lsp(stdout)

      # Initialized notification
      send_lsp_notification(stdin, "initialized", {})

      # Open document
      send_lsp_notification(stdin, "textDocument/didOpen", {
        textDocument: {uri: uri, languageId: ext[1..], version: 1, text: content}
      })

      # Make request
      params = if operation == "documentSymbol"
                 {textDocument: {uri: uri}}
               elsif operation == "workspaceSymbol"
                 {query: ""}
               else
                 {textDocument: {uri: uri}, position: {line: line, character: char}}
               end
      params[:context] = {includeDeclaration: true} if operation == "findReferences"

      send_lsp(stdin, 2, lsp_method, params)
      result = read_lsp(stdout)

      # Shutdown
      send_lsp(stdin, 3, "shutdown", nil)
      send_lsp_notification(stdin, "exit", nil)

      format_lsp_result(result, operation)
    end
  rescue Errno::ENOENT => e
    {error: "LSP server not found: #{server_cmd.first}"}
  rescue => e
    {error: "LSP error: #{e.message}"}
  end

  def send_lsp(io, id, method, params)
    msg = {jsonrpc: "2.0", id: id, method: method, params: params}.to_json
    io.write("Content-Length: #{msg.bytesize}\r\n\r\n#{msg}")
    io.flush
  end

  def send_lsp_notification(io, method, params)
    msg = {jsonrpc: "2.0", method: method, params: params}.to_json
    io.write("Content-Length: #{msg.bytesize}\r\n\r\n#{msg}")
    io.flush
  end

  def read_lsp(io)
    headers = {}
    while (line = io.gets&.strip) && !line.empty?
      key, val = line.split(": ", 2)
      headers[key] = val
    end
    return nil unless headers["Content-Length"]

    body = io.read(headers["Content-Length"].to_i)
    JSON.parse(body)
  end

  def format_lsp_result(response, operation)
    return {error: response["error"]["message"]} if response&.dig("error")

    result = response&.dig("result")
    return "No results" if result.nil? || (result.is_a?(Array) && result.empty?)

    case operation
    when "hover"
      contents = result["contents"]
      contents.is_a?(Hash) ? contents["value"] : contents.to_s
    when "goToDefinition", "findReferences", "goToImplementation"
      locations = result.is_a?(Array) ? result : [result]
      locations.map do |loc|
        uri = loc["uri"] || loc["targetUri"]
        range = loc["range"] || loc["targetRange"]
        path = uri.sub("file://", "")
        "#{path}:#{range["start"]["line"] + 1}:#{range["start"]["character"] + 1}"
      end.join("\n")
    when "documentSymbol", "workspaceSymbol"
      symbols = result.is_a?(Array) ? result : [result]
      symbols.map { |s| "#{s["kind"]}: #{s["name"]} @ line #{s.dig("range", "start", "line")&.+(1) || s.dig("location", "range", "start", "line")&.+(1)}" }.join("\n")
    else
      result.to_json
    end
  end

  def killshell(args)
    id = args["shell_id"]
    shell = $background_shells[id]
    return {error: "Shell not found: #{id}"} unless shell

    Process.kill("TERM", shell[:pid])
    $background_shells.delete(id)
    "Killed: #{id}"
  rescue Errno::ESRCH
    $background_shells.delete(id)
    "Process already terminated"
  end

  def enterplanmode(_args)
    $plan_mode = true
    "Plan mode enabled"
  end

  def exitplanmode(_args)
    $plan_mode = false
    "Plan mode disabled"
  end

  def skill(args)
    # Skills are custom slash commands - would need skill registry
    skill_name = args["skill"]
    skill_args = args["args"] || ""

    # Built-in skills could be implemented here
    case skill_name
    when "commit"
      bash({"command" => "git add -A && git commit -m '#{skill_args}'"})
    when "status"
      bash({"command" => "git status"})
    else
      {error: "Unknown skill: #{skill_name}. Available: commit, status"}
    end
  end
end

class MCPServer
  def initialize
    STDERR.puts "[sys-tools-mcp] Starting with #{TOOLS.length} tools..."
  end

  def run
    STDOUT.sync = true
    STDIN.each_line do |line|
      next if line.strip.empty?
      request = JSON.parse(line.strip)
      response = handle(request)
      STDOUT.puts JSON.generate(response) if response
    rescue JSON::ParserError => e
      STDERR.puts "[sys-tools-mcp] Parse error: #{e.message}"
    rescue => e
      STDERR.puts "[sys-tools-mcp] Error: #{e.class}: #{e.message}"
      STDOUT.puts JSON.generate({jsonrpc: "2.0", id: request&.dig("id"), error: {code: -32603, message: e.message}})
    end
  end

  def handle(request)
    id = request["id"]
    method = request["method"]
    params = request["params"] || {}

    STDERR.puts "[sys-tools-mcp] #{method}" unless method&.start_with?("notifications/")

    result = case method
    when "initialize"
      {
        protocolVersion: "2024-11-05",
        capabilities: {tools: {}},
        serverInfo: {name: "sys-tools", version: "1.0.0"}
      }
    when "notifications/initialized"
      return nil
    when "tools/list"
      {tools: TOOLS}
    when "tools/call"
      name = params["name"]
      args = params["arguments"] || {}
      result = ToolExecutor.execute(name, args)
      if result.is_a?(Hash) && result[:error]
        {content: [{type: "text", text: result[:error]}], isError: true}
      else
        {content: [{type: "text", text: result.to_s}]}
      end
    when "ping"
      {}
    else
      return {jsonrpc: "2.0", id: id, error: {code: -32601, message: "Unknown: #{method}"}}
    end

    result ? {jsonrpc: "2.0", id: id, result: result} : nil
  end
end

MCPServer.new.run
