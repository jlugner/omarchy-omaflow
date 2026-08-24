# frozen_string_literal: true

require 'fileutils'
require 'tempfile'
require 'tmpdir'

module Omaflow
  module Agent
    SUPPORTED = %w[codex claude grok].freeze
    OUTPUT_CAP = 65_536

    CLAUDE_DISALLOWED_TOOLS = %w[Bash Edit Write NotebookEdit Read Glob Grep Task WebFetch WebSearch TodoWrite].freeze

    module_function

    def budget = ENV.fetch('OMAFLOW_AGENT_TIMEOUT', '180')

    def resolve(requested = nil)
      candidates = [requested, ENV.fetch('OMAFLOW_AGENT', nil), configured, omarchy_default]
      explicit = candidates.find do |candidate|
        candidate.to_s != '' && candidate != 'auto' && SUPPORTED.include?(candidate) && Sys.which(candidate)
      end
      explicit || SUPPORTED.find { Sys.which(it) }
    end

    def configured = Store.read_json(Paths.config_file, {})['agent']

    def omarchy_default
      Store.safe_read(Paths.omarchy_default_agent_file, max_bytes: 4096).strip
    rescue StandardError
      nil
    end

    def run(backend, task, timeout: budget)
      answer = case backend
               when 'codex' then run_codex(task, timeout:)
               when 'claude' then run_claude(task, timeout:)
               when 'grok' then run_grok(task, timeout:)
               end
      answer&.byteslice(0, OUTPUT_CAP)
    end

    def with_scratch_dir
      Paths.ensure_dirs
      Dir.mktmpdir('.agent-cwd', Paths.state_dir) { yield it }
    end

    def run_codex(task, timeout:)
      with_scratch_dir do |scratch|
        out = Tempfile.create('.agent', Paths.state_dir)
        out.close
        ok = system('timeout', '--kill-after=10', timeout.to_s, 'codex', 'exec',
                    '--skip-git-repo-check', '--sandbox', 'read-only',
                    '--ephemeral', '--ignore-user-config', '--ignore-rules',
                    '--cd', scratch,
                    '--config', 'notify=[]', '--config', 'model_reasoning_effort="low"',
                    '--output-last-message', out.path, task,
                    out: File::NULL, err: File::NULL, chdir: scratch)
        ok ? File.open(out.path) { it.read(OUTPUT_CAP) }.to_s : nil
      ensure
        File.delete(out.path) if out && File.exist?(out.path)
      end
    end

    def run_claude(task, timeout:)
      with_scratch_dir do |scratch|
        output, ok = Sys.capture('claude', '-p', task, '--output-format', 'text',
                                 '--strict-mcp-config', '--setting-sources', '',
                                 '--disallowedTools', *CLAUDE_DISALLOWED_TOOLS,
                                 timeout:, chdir: scratch)
        ok ? output : nil
      end
    end

    def run_grok(task, timeout:)
      with_scratch_dir do |scratch|
        output, ok = Sys.capture('grok', '-p', task, '--output-format', 'plain',
                                 '--tools', '', '--disable-web-search',
                                 timeout:, chdir: scratch)
        ok ? output : nil
      end
    end

    def extract_json(text)
      [text, fenced(text), braced(text)].each do |candidate|
        next unless candidate

        parsed = Store.parse_json(candidate, {})
        return parsed unless parsed.empty?
      end
      nil
    end

    def extract_json_array(text)
      [text, fenced(text), bracketed(text)].each do |candidate|
        next unless candidate

        parsed = JSON.parse(candidate)
        return parsed if parsed.is_a?(Array)
      rescue JSON::ParserError
        next
      end
      nil
    end

    def fenced(text)
      text[/^```[a-z]*\n(.*?)^```/m, 1]
    end

    def braced(text)
      text.tr("\n", ' ')[/\{.*\}/m]
    end

    def bracketed(text)
      text.tr("\n", ' ')[/\[.*\]/m]
    end
  end
end
