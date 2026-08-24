# frozen_string_literal: true

module Omaflow
  module CLI
    HELP = <<~HELP
      Omaflow CLI — everything the overlay can do, scriptable.

        omaflow                     open the inspector overlay
        omaflow list                list rules
        omaflow author "<text>" [--agent codex|claude|grok]
        omaflow stage <accept|reject|show>
        omaflow run <id> [--dry-run]
        omaflow enable <id> | disable <id>
        omaflow delete <id>
        omaflow revert <exec-id>
        omaflow log [n]
        omaflow validate <file|id>
        omaflow agent [backend]     show or set the authoring backend
        omaflow webhooks [add <name> <url> [format] | remove <name>]
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
      when 'list' then list
      when 'author' then author_command(argv)
      when 'stage' then stage(argv)
      when 'run' then run_command(argv)
      when 'enable' then set_enabled(argv.first, value: true)
      when 'disable' then set_enabled(argv.first, value: false)
      when 'delete' then delete(argv.first)
      when 'revert' then Executor.revert(argv.first.to_s)
      when 'log' then show_log(argv.first)
      when 'validate' then validate_command(argv.first)
      when 'agent' then agent(argv.first)
      when 'webhooks' then webhooks(argv)
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
        dot = rule['enabled'] ? '●' : '○'
        last = rule['lastFired'].to_s.empty? ? '' : "  (last: #{rule['lastFired']})"
        puts "#{dot} #{rule['id']}  [#{rule['triggerSummary']}] → #{rule['actionsSummary']}#{last}"
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
        Store.with_lock('.staging.lock', timeout: 10) { File.delete(Paths.staging_file) if File.exist?(Paths.staging_file) }
        puts 'Staged rule discarded'
      else
        warn 'Usage: omaflow stage <accept|reject|show>'
        return 2
      end
      0
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
      id = free_rule_id(rule['id'])
      unless id
        warn 'Staged rule has an invalid id'
        return 1
      end
      rule = rule.merge('id' => id, 'createdAt' => Sys.now_iso)
      errors, = Validator.new(rule).validate
      unless errors.empty?
        warn 'Staged rule no longer validates'
        return 1
      end
      Store.write_json(Paths.rule_file(id), rule)
      File.delete(Paths.staging_file)
      Store.reindex
      Store.log_append({ 'at' => Sys.now_iso, 'kind' => 'created', 'ruleId' => id, 'status' => 'ok' })
      puts "Installed rule: #{id}"
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
      Store.write_json(path, Store.read_json(path, {}).merge('enabled' => value))
      Store.reindex
      puts "#{id}: enabled=#{value}"
      0
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
      return 0 unless File.exist?(Paths.log_file)

      File.readlines(Paths.log_file).last((count || 15).to_i).each do |line|
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
        hooks = Store.read_json(Paths.webhooks_file, {})
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

    def vocabulary
      Vocabulary::TRIGGERS.each { puts "trigger #{it}" }
      Vocabulary::CONDITIONS.each { puts "condition #{it}" }
      Vocabulary::ACTIONS.each { puts "action #{it}" }
      0
    end
  end
end
