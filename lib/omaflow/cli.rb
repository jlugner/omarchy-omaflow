# frozen_string_literal: true

require 'fileutils'
require 'securerandom'

module Omaflow
  module CLI
    HELP = <<~HELP
      Omaflow CLI — everything the overlay can do, scriptable.

        omaflow                     open the inspector overlay
        omaflow setup [--yes]       wire the CLI, menu, and optional hotkey
        omaflow list                list rules
        omaflow author "<text>" [--agent codex|claude|grok]
        omaflow stage-file <path>
        omaflow stage <accept|reject|show>
        omaflow describe <id>
        omaflow run <id> [--dry-run]
        omaflow enable <id> | disable <id>
        omaflow disarm <id>
        omaflow delete <id>
        omaflow revert <exec-id>
        omaflow log [n]
        omaflow validate <file|id>
        omaflow agent [backend]     show or set the authoring backend
        omaflow scripts [add <name> <absolute-path> [description] | remove <name>]
        omaflow webhooks [add <name> <url> [format] | remove <name>]
        omaflow trigger <name> [key=value ...]
        omaflow vocabulary          list supported trigger/condition/action types
        omaflow poke                run one engine evaluation now
    HELP

    module_function

    def dispatch(program, argv)
      Paths.ensure_dirs
      case program
      when 'omaflow-eval' then Evaluator.tick(argv.first || 'tick')
      when 'omaflow-run' then run_command(argv)
      when 'omaflow-validate' then validate_command(argv.first)
      when 'omaflow-author' then author_command(argv)
      else main(argv)
      end
    end

    def main(argv)
      command = argv.shift || 'open'
      case command
      when 'open' then open_overlay
      when 'setup' then Onboarding.setup(argv)
      when 'first-run' then Onboarding.first_run
      when 'list' then list
      when 'author' then author_command(argv)
      when 'stage-file' then stage_file(argv.first)
      when 'stage' then stage(argv)
      when 'describe' then describe(argv.first)
      when 'run' then run_command(argv)
      when 'enable' then set_enabled(argv.first, value: true)
      when 'disable' then set_enabled(argv.first, value: false)
      when 'disarm' then disarm(argv.first)
      when 'delete' then delete(argv.first)
      when 'revert' then Executor.revert(argv.first.to_s)
      when 'log' then show_log(argv.first)
      when 'validate' then validate_command(argv.first)
      when 'agent' then agent(argv.first)
      when 'scripts' then scripts(argv)
      when 'webhooks' then webhooks(argv)
      when 'trigger' then trigger(argv)
      when 'vocabulary' then vocabulary
      when 'poke' then Evaluator.tick('cli')
      when '-h', '--help', 'help' then puts HELP
      else
        warn "Unknown command: #{command} (see omaflow --help)"
        return 2
      end.then { it.is_a?(Integer) ? it : 0 }
    end

    def open_overlay
      output, = Sys.capture('omarchy-shell', 'shell', 'summon', 'jesperlugner.omaflow', '{}')
      return 0 if output.strip == 'ok'

      warn "Omaflow is not available. Enable it with:\n  omarchy plugin enable jesperlugner.omaflow"
      1
    end

    def list
      Store.reindex
      Store.read_json(Paths.index_file, {}).fetch('rules', []).each do |rule|
        dot = if rule['armed'] then '◉'
              elsif rule['enabled'] then '●'
              else '○'
              end
        status = []
        status << 'armed' if rule['armed']
        status << "last: #{rule['lastFired']}" unless rule['lastFired'].to_s.empty?
        suffix = status.empty? ? '' : "  (#{status.join('; ')})"
        puts "#{dot} #{rule['id']}  [#{rule['triggerSummary']}] → #{rule['actionsSummary']}#{suffix}"
      end
      0
    end

    def author_command(argv)
      agent = nil
      request = nil
      until argv.empty?
        arg = argv.shift
        case arg
        when '--agent' then agent = argv.shift
        when /\A-/ then return unknown_option(arg)
        else request = arg
        end
      end
      Author.compile(request, agent:)
    end

    def unknown_option(arg)
      warn "Unknown option: #{arg}"
      2
    end

    def stage(argv)
      unless File.exist?(Paths.staging_file)
        warn 'Nothing staged'
        return 1
      end
      case argv.first || 'show'
      when 'show' then puts JSON.pretty_generate(Store.read_json(Paths.staging_file, {}))
      when 'accept' then return stage_accept
      when 'reject'
        Store.with_lock('.staging.lock', timeout: 10) { FileUtils.rm_f(Paths.staging_file) }
        puts 'Staged rule discarded'
      else
        warn 'Usage: omaflow stage <accept|reject|show>'
        return 2
      end
      0
    end

    def stage_file(path)
      unless path
        warn 'Usage: omaflow stage-file <path>'
        return 2
      end
      rule = Store.load_json!(path, {})
      errors, warnings = Validator.new(rule).validate
      return stage_file_error(rule['name'].to_s, errors) unless errors.empty?

      staging = {
        'status' => 'ready',
        'agent' => 'manual',
        'request' => rule['name'],
        'updatedAt' => Sys.now_iso,
        'rule' => rule,
        'warnings' => warnings.map { "warn: #{it}" }
      }
      return 1 unless write_staging(staging).zero?

      puts "Staged rule: #{rule['name']}"
      0
    rescue StandardError
      stage_file_error(File.basename(path.to_s), ['not a JSON object'])
    end

    def stage_file_error(request, errors)
      lines = errors.map { "error: #{it}" }
      lines.each { puts it }
      staging = {
        'status' => 'error',
        'agent' => 'manual',
        'request' => request,
        'updatedAt' => Sys.now_iso,
        'error' => lines.join("\n")
      }
      write_staging(staging)
      1
    end

    def write_staging(staging)
      return 0 if Store.with_lock('.staging.lock', timeout: 10) { Store.write_json(Paths.staging_file, staging) }

      warn 'Staging is busy'
      1
    end

    def describe(id)
      path = id && Paths.rule_file(id)
      unless path && File.exist?(path)
        warn "No such rule: #{id}"
        return 1
      end
      puts JSON.pretty_generate(Store.load_json!(path, {}))
      0
    rescue StandardError
      warn "Rule file is not valid JSON: #{path}"
      1
    end

    def stage_accept
      result = 1
      locked = Store.with_lock('.staging.lock', timeout: 10) { result = install_staged }
      unless locked
        warn 'Staging is busy'
        return 1
      end
      result
    end

    def install_staged
      staged = Store.read_json(Paths.staging_file, {})
      unless staged['status'] == 'ready'
        warn 'Staged rule is not ready'
        return 1
      end
      rule = staged['rule']
      replacing = staged['agent'] == 'manual' && rule.key?('createdAt') && File.exist?(Paths.rule_file(rule['id']).to_s)
      id = replacing ? rule['id'] : free_rule_id(rule['id'])
      unless id
        warn 'Staged rule has an invalid id'
        return 1
      end
      rule = rule.merge('id' => id, 'createdAt' => replacing ? rule['createdAt'] : Sys.now_iso)
      errors, = Validator.new(rule).validate
      unless errors.empty?
        warn 'Staged rule no longer validates'
        return 1
      end
      if replacing
        Store.write_json(Paths.rule_file(id), rule)
      else
        unless Store.install_json(Paths.rule_file(id), rule)
          warn 'Rule id collided; try again'
          return 1
        end
      end
      File.delete(Paths.staging_file)
      Store.reindex
      Store.log_append({ 'at' => Sys.now_iso, 'kind' => replacing ? 'updated' : 'created', 'ruleId' => id, 'status' => 'ok' })
      puts "#{replacing ? 'Updated' : 'Installed'} rule: #{id}"
      0
    end

    def free_rule_id(base_id)
      return nil unless Paths.rule_file(base_id.to_s)

      candidates = [base_id] + (2..99).map { "#{base_id}-#{it}" }
      candidates.find do |id|
        path = Paths.rule_file(id)
        path && !File.exist?(path)
      end
    end

    def run_command(argv)
      dry_run = false
      trigger = 'manual'
      revert_id = nil
      rule_id = nil
      until argv.empty?
        arg = argv.shift
        case arg
        when '--dry-run' then dry_run = true
        when '--trigger' then trigger = argv.shift.to_s
        when '--revert' then revert_id = argv.shift.to_s
        when /\A-/ then return unknown_option(arg)
        else rule_id = arg
        end
      end
      return Executor.revert(revert_id) if revert_id

      unless rule_id
        warn 'Usage: omaflow-run <rule-id> [--dry-run] [--trigger d] | --revert <exec-id>'
        return 2
      end
      Executor.run(rule_id, dry_run:, trigger:)
    end

    def set_enabled(id, value:)
      path = id && Paths.rule_file(id)
      unless path
        warn 'Invalid rule id'
        return 2
      end
      unless File.exist?(path)
        warn "No such rule: #{id}"
        return 1
      end
      rule = begin
        Store.load_json!(path, {})
      rescue StandardError
        nil
      end
      unless rule
        warn "Rule file is not valid JSON: #{path}"
        return 1
      end
      Store.write_json(path, rule.merge('enabled' => value))
      Store.reindex
      puts "#{id}: enabled=#{value}"
      0
    end

    def disarm(id)
      unless Paths.rule_file(id.to_s)
        warn 'Invalid rule id'
        return 2
      end

      result = false
      locked = Store.with_lock('.eval.lock', timeout: 10) { result = Store.disarm(id, log: true) }
      unless locked
        warn 'Evaluation is busy'
        return 1
      end
      unless result
        warn "Rule is not armed: #{id}"
        return 1
      end

      puts "Disarmed rule: #{id}"
      0
    rescue StandardError => e
      warn "Could not disarm #{id}: #{e.message}"
      1
    end

    def delete(id)
      path = id && Paths.rule_file(id)
      unless path
        warn 'Invalid rule id'
        return 2
      end
      unless File.exist?(path)
        warn "No such rule: #{id}"
        return 1
      end
      File.delete(path)
      Store.reindex
      Store.log_append({ 'at' => Sys.now_iso, 'kind' => 'deleted', 'ruleId' => id, 'status' => 'ok' })
      puts "Deleted rule: #{id}"
      0
    end

    def show_log(count)
      lines = begin
        Store.safe_read(Paths.log_file, max_bytes: 4_194_304).lines
      rescue StandardError
        nil
      end
      return 0 unless lines

      lines.last((count || 15).to_i).each do |line|
        entry = Store.parse_json(line, {})
        next if entry.empty?

        trigger = entry['trigger'] ? "  [#{entry['trigger']}]" : ''
        puts "#{entry['at']}  #{entry['kind']}  #{entry['ruleId'] || '-'}  #{entry['status']}#{trigger}"
      end
      0
    end

    def validate_command(target)
      path = target && File.exist?(target.to_s) ? target : target && Paths.rule_file(target)
      unless path
        warn 'Invalid rule id'
        return 2
      end
      errors, warnings = Validator.validate_file(path)
      warnings.each { puts "warn: #{it}" }
      errors.each { puts "error: #{it}" }
      errors.empty? ? 0 : 1
    end

    def agent(backend)
      if backend.nil?
        puts "resolved: #{Agent.resolve || 'none'}"
        puts "omaflow config: #{Agent.configured || 'unset'}"
        puts "omarchy default: #{Agent.omarchy_default || 'unset'}"
        return 0
      end
      unless (Agent::SUPPORTED + ['auto']).include?(backend)
        warn 'Supported: codex, claude, grok, auto'
        return 2
      end
      Store.write_json(Paths.config_file, Store.read_json(Paths.config_file, {}).merge('agent' => backend))
      puts "Authoring agent set to: #{backend}"
      0
    end

    def scripts(argv)
      subcommand = argv.shift || 'list'
      case subcommand
      when 'list' then scripts_list
      when 'add', 'remove' then scripts_edit(subcommand, argv)
      else
        warn 'Usage: omaflow scripts [list | add <name> <absolute-path> [description] | remove <name>]'
        2
      end
    end

    def scripts_list
      ScriptRegistry.entries.sort.each do |name, value|
        status = ScriptRegistry.available(name) ? '✓' : '!'
        puts "#{status} #{name}  ·  #{value['source']}  ·  #{ScriptRegistry.description(value)}"
      end
      0
    end

    def scripts_edit(subcommand, argv)
      result = 1
      locked = Store.with_lock('.scripts.lock', timeout: 10) do
        configured = begin
          File.exist?(Paths.scripts_file) ? Store.load_json!(Paths.scripts_file, {}) : {}
        rescue StandardError
          warn "Script config is not valid JSON: #{Paths.scripts_file}"
          next
        end
        result = subcommand == 'add' ? script_add(configured, argv) : script_remove(configured, argv.first)
      end
      unless locked
        warn 'Script config is busy'
        return 1
      end
      result
    end

    def script_add(configured, argv)
      name, requested_path, *description_words = argv
      unless ScriptRegistry.valid_name?(name) && requested_path
        warn 'Usage: omaflow scripts add <lowercase-name> <absolute-path> [description]'
        return 2
      end
      if ScriptRegistry.built_in?(name)
        warn "Built-in script names cannot be replaced: #{name}"
        return 2
      end
      path = ScriptRegistry.canonical_path(requested_path) if requested_path.start_with?('/')
      unless path
        warn 'Script and its directory must be owner- or root-owned, executable, and not group/world writable; try chmod go-w'
        return 2
      end
      description = description_words.join(' ').strip
      configured[name] = { 'path' => path, 'description' => description, 'addedAt' => Sys.now_iso }
      Store.write_json(Paths.scripts_file, configured)
      ScriptRegistry.reset!
      puts "Script allowed: #{name}"
      0
    end

    def script_remove(configured, name)
      unless ScriptRegistry.valid_name?(name)
        warn 'Usage: omaflow scripts remove <name>'
        return 2
      end
      if ScriptRegistry.built_in?(name)
        warn "Built-in scripts cannot be removed: #{name}"
        return 2
      end
      unless configured.key?(name)
        warn "No allowed script named: #{name}"
        return 1
      end
      configured.delete(name)
      Store.write_json(Paths.scripts_file, configured)
      ScriptRegistry.reset!
      puts "Script removed: #{name}"
      0
    end

    def webhooks(argv)
      subcommand = argv.shift || 'list'
      case subcommand
      when 'list' then webhooks_list(show_urls: argv.first == '--show-urls')
      when 'add', 'remove' then webhooks_edit(subcommand, argv)
      else
        warn 'Usage: omaflow webhooks [list [--show-urls] | add <name> <url> [format] | remove <name>]'
        2
      end
    end

    def webhooks_list(show_urls:)
      hooks = Store.read_json(Paths.webhooks_file, {})
      if hooks.empty?
        puts 'No webhook endpoints configured.'
        puts 'Add one:  omaflow webhooks add <name> <url> [json|slack|discord|ntfy|raw]'
      elsif show_urls
        hooks.each { |name, hook| puts "#{name}  ·  #{hook['format']}  ·  #{hook['url']}" }
      else
        hooks.each do |name, hook|
          origin = hook['url'].to_s[%r{\Ahttps?://[^/]+}] || hook['url']
          puts "#{name}  ·  #{hook['format']}  ·  #{origin}/…"
        end
        puts "(URLs redacted; use 'omaflow webhooks list --show-urls' for full values)"
      end
      0
    end

    def webhooks_edit(subcommand, argv)
      result = 1
      locked = Store.with_lock('.webhooks.lock', timeout: 10) do
        hooks = begin
          File.exist?(Paths.webhooks_file) ? Store.load_json!(Paths.webhooks_file, {}) : {}
        rescue StandardError
          warn "Webhook config is not valid JSON: #{Paths.webhooks_file}"
          next
        end
        result = subcommand == 'add' ? webhook_add(hooks, argv) : webhook_remove(hooks, argv.first)
      end
      unless locked
        warn 'Webhook config is busy'
        return 1
      end
      result
    end

    def webhook_add(hooks, argv)
      name, url, format = argv
      format ||= 'json'
      unless name.to_s.match?(/\A[a-z0-9][a-z0-9-]{0,30}\z/)
        warn 'Name must be a short lowercase slug'
        return 2
      end
      unless Vocabulary::WEBHOOK_FORMATS.include?(format)
        warn 'Format must be json|slack|discord|ntfy|raw'
        return 2
      end
      case url.to_s
      when %r{\Ahttps://} then nil
      when %r{\Ahttp://} then warn "warning: #{url} is not HTTPS — payloads will travel unencrypted"
      else
        warn 'URL must start with https:// or http://'
        return 2
      end
      hooks[name] = { 'url' => url, 'format' => format, 'addedAt' => Sys.now_iso }
      Store.write_json(Paths.webhooks_file, hooks)
      puts "Webhook endpoint added: #{name} (#{format})"
      0
    end

    def webhook_remove(hooks, name)
      hooks.delete(name.to_s)
      Store.write_json(Paths.webhooks_file, hooks)
      puts "Webhook endpoint removed: #{name}"
      0
    end

    def trigger(argv)
      name = argv.shift.to_s
      unless name.match?(Validator::SLUG)
        warn 'Custom event name must be a lowercase slug'
        return 2
      end
      data = trigger_data(argv)
      return 2 unless data

      filename = "#{Time.now.strftime('%Y%m%d%H%M%S%6N')}-#{Process.pid}-#{SecureRandom.hex(4)}.json"
      Store.write_json(File.join(Paths.inbox_dir, filename), { 'name' => name, 'data' => data, 'at' => Sys.now_iso })
      Evaluator.tick("custom:#{name}")
    end

    def trigger_data(argv)
      if argv.size > 10
        warn 'Custom events accept at most 10 data keys'
        return nil
      end
      argv.each_with_object({}) do |pair, data|
        key, value = pair.split('=', 2)
        unless safe_event_string?(key) && safe_event_string?(value) && !%w[name at trigger].include?(key) && !data.key?(key)
          warn 'Custom event data must be unique plain key=value strings'
          return nil
        end
        data[key] = value
      end
    end

    def safe_event_string?(value)
      value.is_a?(String) && value.bytesize.between?(1, 200) && !value.match?(/[[:cntrl:]]/) && !value.start_with?('-')
    end

    def vocabulary
      Vocabulary::TRIGGERS.each { puts "trigger #{it}" }
      Vocabulary::CONDITIONS.each { puts "condition #{it}" }
      Vocabulary::ACTIONS.each { puts "action #{it}" }
      0
    end
  end
end
