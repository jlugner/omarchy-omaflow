# frozen_string_literal: true

require 'tempfile'

module Omaflow
  module Agent
    SUPPORTED = %w[codex claude grok].freeze
    OUTPUT_CAP = 65_536

    CLAUDE_DISALLOWED_TOOLS = %w[Bash Edit Write NotebookEdit Read Glob Grep Task WebFetch WebSearch TodoWrite].freeze

    module_function

    def budget = ENV.fetch('OMAFLOW_AGENT_TIMEOUT', '180')

    def resolve(requested = nil)
      candidates = [requested, ENV['OMAFLOW_AGENT'], configured, omarchy_default]
      explicit = candidates.find do |candidate|
        candidate.to_s != '' && candidate != 'auto' && SUPPORTED.include?(candidate) && Sys.which(candidate)
      end
      explicit || SUPPORTED.find { Sys.which(it) }
    end

    def configured = Store.read_json(Paths.config_file, {})['agent']

    def omarchy_default
      File.read(Paths.omarchy_default_agent_file).strip
    rescue StandardError
      nil
    end

    def run(backend, task)
      answer = case backend
               when 'codex' then run_codex(task)
               when 'claude' then run_claude(task)
               when 'grok' then run_grok(task)
               end
      answer&.byteslice(0, OUTPUT_CAP)
    end

    def run_codex(task)
      Paths.ensure_dirs
      out = Tempfile.create('.agent', Paths.state_dir)
      out.close
      ok = system('timeout', budget, 'codex', 'exec',
                  '--skip-git-repo-check', '--sandbox', 'read-only',
                  '--ephemeral', '--ignore-user-config', '--ignore-rules',
                  '--config', 'notify=[]', '--config', 'model_reasoning_effort="low"',
                  '--output-last-message', out.path, task,
                  out: File::NULL, err: File::NULL)
      ok ? File.read(out.path) : nil
    ensure
      File.delete(out.path) if out && File.exist?(out.path)
    end

    def run_claude(task)
      output, ok = Sys.capture('claude', '-p', task, '--output-format', 'text',
                               '--strict-mcp-config', '--setting-sources', '',
                               '--disallowedTools', *CLAUDE_DISALLOWED_TOOLS,
                               timeout: budget)
      ok ? output : nil
    end

    def run_grok(task)
      output, ok = Sys.capture('grok', '-p', task, '--output-format', 'plain',
                               '--tools', '', '--disable-web-search',
                               timeout: budget)
      ok ? output : nil
    end

    def extract_json(text)
      [text, fenced(text), braced(text)].each do |candidate|
        next unless candidate

        parsed = Store.parse_json(candidate, {})
        return parsed unless parsed.empty?
      end
      nil
    end

    def fenced(text)
      text[/^```[a-z]*\n(.*?)^```/m, 1]
    end

    def braced(text)
      text.tr("\n", ' ')[/\{.*\}/m]
    end
  end
end
