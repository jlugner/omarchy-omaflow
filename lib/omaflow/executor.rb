# frozen_string_literal: true

require 'securerandom'

module Omaflow
  class Executor
    EXEC_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9-]{0,40}\z/

    HANDLERS = {
      'theme' => :apply_theme,
      'dnd' => :apply_dnd,
      'nightlight' => :apply_nightlight,
      'stay-awake' => :apply_stay_awake,
      'launch' => :apply_launch,
      'workspace' => :apply_workspace,
      'audio-output' => :apply_audio_output,
      'script' => :apply_script,
      'webhook' => :apply_webhook,
      'notify' => :apply_notify
    }.freeze

    SNAPSHOTTED = {
      'theme' => :snapshot_theme,
      'dnd' => :snapshot_dnd,
      'nightlight' => :snapshot_nightlight,
      'stay-awake' => :snapshot_stay_awake,
      'audio-output' => :snapshot_audio_output
    }.freeze
    SNAPSHOT_FILE_LIMIT = 200

    def self.run(rule_id, dry_run: false, trigger: 'manual', trigger_data: {}, respect_cooldown: false)
      locked = Store.with_lock('.run.lock') { return new.execute(rule_id, dry_run:, trigger:, trigger_data:, respect_cooldown:) }
      locked ? 0 : fail_stderr('Another Omaflow run is holding the lock')
    end

    def self.revert(exec_id)
      locked = Store.with_lock('.run.lock') { return new.revert(exec_id) }
      locked ? 0 : fail_stderr('Another Omaflow run is holding the lock')
    end

    def self.fail_stderr(message)
      warn message
      1
    end

    def execute(rule_id, dry_run:, trigger:, trigger_data:, respect_cooldown:)
      path = Paths.rule_file(rule_id)
      return self.class.fail_stderr('Invalid rule id') unless path
      return self.class.fail_stderr("No such rule: #{rule_id}") unless File.exist?(path)

      @rule = Store.read_json(path, {})
      @rule_id = rule_id
      @trigger_desc = trigger
      @trigger_data = trigger_data.is_a?(Hash) ? trigger_data : {}
      @exec_id = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}"

      errors, = Validator.new(@rule).validate
      errors << "rule id '#{@rule['id']}' does not match its filename" unless @rule['id'] == rule_id
      return log_invalid(errors) unless errors.empty?

      return 0 if respect_cooldown && !cooldown_over?

      snapshot = dry_run ? {} : capture_snapshot
      return 1 if snapshot.nil?

      results, status = apply_actions(dry_run:)
      status = roll_back(snapshot, results:) if status == 'failed'
      record_run(results:, status:, dry_run:)
      print_plan(results) if dry_run
      status == 'ok' ? 0 : 1
    end

    def revert(exec_id)
      return self.class.fail_stderr('Invalid execution id') unless exec_id.to_s.match?(EXEC_ID_PATTERN)

      path = File.join(Paths.snapshots_dir, "#{exec_id}.json")
      return self.class.fail_stderr("No snapshot for execution: #{exec_id}") unless File.exist?(path)

      snapshot = begin
        parsed = JSON.parse(Store.safe_read(path))
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end
      return self.class.fail_stderr("Snapshot is not valid JSON: #{path}") unless snapshot

      unless snapshot_revertible?(snapshot)
        detail = 'execution has no revertible actions'
        Store.log_append({ 'at' => Sys.now_iso, 'kind' => 'revert', 'execId' => exec_id,
                           'status' => 'not-revertible', 'detail' => detail })
        return self.class.fail_stderr(detail.capitalize)
      end

      status = restore_snapshot(snapshot)
      irreversible = snapshot_irreversible_actions(snapshot)
      status = 'partial' if status == 'ok' && !irreversible.empty?
      detail = "irreversible actions remain: #{irreversible.join(', ')}" unless irreversible.empty?
      entry = { 'at' => Sys.now_iso, 'kind' => 'revert', 'execId' => exec_id, 'status' => status }
      entry['detail'] = detail if detail
      Store.log_append(entry)
      notify_revert(exec_id, status:, irreversible:)
      status == 'ok' ? 0 : 1
    end

    private

    def rule_name = @rule['name'].to_s

    def log_invalid(errors)
      detail = errors.map { "error: #{it}" }.join("\n")
      Store.log_append({ 'at' => Sys.now_iso, 'kind' => 'run', 'execId' => @exec_id, 'ruleId' => @rule_id,
                         'status' => 'invalid', 'detail' => detail })
      warn "Rule failed validation:\n#{detail}"
      1
    end

    def action_types = (@rule['actions'] || []).map { it['type'] }

    def capture_snapshot
      revertible = action_types.select { SNAPSHOTTED.key?(it) }.uniq
      irreversible = action_types.reject { SNAPSHOTTED.key?(it) }.uniq
      snapshot = { '_meta' => { 'revertibleActions' => revertible, 'irreversibleActions' => irreversible } }
      SNAPSHOTTED.each do |type, capture|
        next unless action_types.include?(type)

        key, value = send(capture)
        return snapshot_failed(type) unless value

        snapshot[key] = value
      end
      Store.write_json(File.join(Paths.snapshots_dir, "#{@exec_id}.json"), snapshot)
      prune_snapshots
      snapshot
    end

    def snapshot_failed(field)
      Store.log_append({ 'at' => Sys.now_iso, 'kind' => 'run', 'execId' => @exec_id, 'ruleId' => @rule_id,
                         'status' => 'snapshot-failed', 'detail' => "could not capture current #{field}" })
      Sys.notify('Omaflow rule skipped', "Could not snapshot current #{field} for rollback")
      nil
    end

    def prune_snapshots
      cutoff = Time.now - (14 * 86_400)
      names = []
      Dir.each_child(Paths.snapshots_dir) do |name|
        next unless name.end_with?('.json')

        names << name
        break if names.size >= SNAPSHOT_FILE_LIMIT
      end
      names.each do |name|
        path = File.join(Paths.snapshots_dir, name)
        File.delete(path) if File.mtime(path) < cutoff
      rescue StandardError
        nil
      end
    end

    def snapshot_theme
      output, ok = Sys.capture('omarchy', 'theme', 'current')
      ['theme', ok && !output.strip.empty? ? output.strip : nil]
    end

    def snapshot_dnd
      output, ok = Sys.capture('omarchy-shell', 'notifications', 'dndState')
      value = output.strip
      ['dnd', ok && %w[on off].include?(value) ? value : nil]
    end

    def snapshot_nightlight
      output, ok = Sys.capture('omarchy-shell', 'nightlight', 'status')
      return ['nightlight', nil] unless ok

      value = begin
        parsed = JSON.parse(output)
        if parsed.is_a?(Hash)
          parsed['enabled'] ? 'on' : 'off'
        end
      rescue StandardError
        %w[on off].include?(output.strip) ? output.strip : nil
      end
      ['nightlight', value]
    end

    def snapshot_stay_awake
      output, ok = Sys.capture('omarchy-shell', 'idle', 'status')
      value = begin
        parsed = JSON.parse(output)
        [true, false].include?(parsed['stayAwake']) ? parsed['stayAwake'].to_s : nil
      rescue StandardError
        nil
      end
      ['stayAwake', ok ? value : nil]
    end

    def snapshot_audio_output
      output, ok = Sys.capture('pactl', 'get-default-sink')
      ['defaultSink', ok && !output.strip.empty? ? output.strip : nil]
    end

    def cooldown_over?
      last = Store.read_json(Paths.cooldowns_file, {}).dig(@rule_id, 'lastFiredEpoch').to_i
      Time.now.to_i - last >= @rule.fetch('cooldownSeconds', 60)
    end

    def apply_actions(dry_run:)
      results = []
      (@rule['actions'] || []).each do |action|
        if dry_run
          results << { 'type' => action['type'], 'plan' => action, 'ok' => true }
          next
        end
        detail, ok = begin
          send(HANDLERS.fetch(action['type']), action)
        rescue StandardError => e
          ["exception: #{e.class}: #{e.message}", false]
        end
        results << { 'type' => action['type'], 'detail' => detail, 'ok' => ok }
        return [results, 'failed'] unless ok
      end
      [results, 'ok']
    end

    def roll_back(snapshot, results:)
      revert_status = restore_snapshot(snapshot)
      irreversible = results.filter_map do |result|
        result['type'] if result['ok'] && !SNAPSHOTTED.key?(result['type'])
      end.uniq
      revert_status = 'partial' if revert_status == 'ok' && !irreversible.empty?
      entry = { 'at' => Sys.now_iso, 'kind' => 'revert', 'execId' => @exec_id, 'status' => revert_status }
      entry['detail'] = "irreversible actions remain: #{irreversible.join(', ')}" unless irreversible.empty?
      Store.log_append(entry)
      if revert_status == 'ok'
        Sys.notify('Omaflow rule failed', "#{rule_name} — revertible changes rolled back")
      else
        Sys.notify('Omaflow rule failed', "#{rule_name} — rollback incomplete, see omaflow log")
      end
      'failed'
    end

    def snapshot_revertible?(snapshot) = snapshot.keys.any? { it != '_meta' }

    def snapshot_irreversible_actions(snapshot)
      meta = snapshot['_meta']
      meta.is_a?(Hash) ? Array(meta['irreversibleActions']).grep(String) : []
    end

    def notify_revert(exec_id, status:, irreversible:)
      message =
        if status == 'ok'
          "Reverted execution #{exec_id}"
        elsif !irreversible.empty?
          "Reverted only reversible changes in #{exec_id}; #{irreversible.join(', ')} remains applied"
        else
          "Revert of #{exec_id} was incomplete"
        end
      Sys.notify('Omaflow', message)
    end

    def restore_snapshot(snapshot)
      failures = 0
      restore = lambda do |value, *argv|
        failures += 1 if value && !Sys.run(*argv, value)
      end
      restore.call(snapshot['theme'], 'omarchy', 'theme', 'set')
      restore.call(snapshot['dnd'], 'omarchy-shell', 'notifications', 'setDnd')
      restore.call(snapshot['defaultSink'], 'pactl', 'set-default-sink')
      if %w[on off].include?(snapshot['nightlight'])
        subcommand = snapshot['nightlight'] == 'on' ? 'enable' : 'disable'
        failures += 1 unless Sys.run('omarchy-shell', 'nightlight', subcommand)
      end
      if %w[true false].include?(snapshot['stayAwake'])
        subcommand = snapshot['stayAwake'] == 'true' ? 'disable' : 'enable'
        failures += 1 unless Sys.run('omarchy-shell', 'idle', subcommand)
      end
      failures.zero? ? 'ok' : 'partial'
    end

    def record_run(results:, status:, dry_run:)
      Store.log_append({ 'at' => Sys.now_iso, 'kind' => dry_run ? 'dry-run' : 'run', 'execId' => @exec_id,
                         'ruleId' => @rule_id, 'ruleName' => rule_name, 'trigger' => @trigger_desc,
                         'status' => status, 'actions' => results })
      return if dry_run

      cooldowns = Store.read_json(Paths.cooldowns_file, {})
      cooldowns[@rule_id] = { 'lastFiredAt' => Sys.now_iso, 'lastFiredEpoch' => Time.now.to_i }
      Store.write_json(Paths.cooldowns_file, cooldowns)
      Store.reindex
    end

    def print_plan(results)
      results.each { puts "would run: #{it['type']} #{JSON.generate(it['plan'].except('type'))}" }
    end

    def apply_theme(action) = [action['name'], Sys.run('omarchy', 'theme', 'set', action['name'])]

    def apply_dnd(action) = [action['state'], Sys.run('omarchy-shell', 'notifications', 'setDnd', action['state'])]

    def apply_nightlight(action)
      subcommand = action['state'] == 'on' ? 'enable' : 'disable'
      [action['state'], Sys.run('omarchy-shell', 'nightlight', subcommand)]
    end

    def apply_stay_awake(action)
      subcommand = action['state'] == 'on' ? 'disable' : 'enable'
      [action['state'], Sys.run('omarchy-shell', 'idle', subcommand)]
    end

    def apply_launch(action)
      desktop_id = Desktop.resolve(action['app'])
      return ["no desktop entry: #{action['app']}", false] unless desktop_id

      Sys.run('hyprctl', 'dispatch', 'workspace', action['workspace'].to_s) if action['workspace']
      Sys.detached('gtk-launch', desktop_id)
      [desktop_id, true]
    end

    def apply_workspace(action) = [action['number'].to_s, Sys.run('hyprctl', 'dispatch', 'workspace', action['number'].to_s)]

    def apply_audio_output(action)
      output, ok = Sys.capture('pactl', '--format=json', 'list', 'sinks')
      sinks = ok ? Store.parse_json(output, []) : []
      sink = sinks.find { "#{it['description']} #{it['name']}".downcase.include?(action['match'].downcase) }
      return ["no sink matches: #{action['match']}", false] unless sink

      [sink['name'], Sys.run('pactl', 'set-default-sink', sink['name'])]
    end

    def apply_script(action)
      script = ScriptRegistry.available(action['name'])
      return ["script unavailable: #{action['name']}", false] unless script

      [action['name'], Sys.run(script['path'], timeout: 30)]
    end

    def apply_webhook(action)
      message = template_message(message: action['message'])
      hook = Store.read_json(Paths.webhooks_file, {})[action['endpoint']]
      return ["no webhook endpoint named: #{action['endpoint']}", false] unless hook.is_a?(Hash)

      url = hook['url'].to_s
      format = hook.fetch('format', 'json')
      well_formed = url.match?(%r{\Ahttps?://}) && Vocabulary::WEBHOOK_FORMATS.include?(format)
      return ["endpoint '#{action['endpoint']}' is malformed in webhooks.json", false] unless well_formed

      body, content_type = webhook_body(format:, message:)
      posted = system('curl', '-q', '-fsS', '--globoff', '--max-time', '15', '-X', 'POST',
                      '-H', "Content-Type: #{content_type}", '--data-raw', body, '--', url,
                      out: File::NULL, err: File::NULL)
      posted ? ["#{action['endpoint']} (#{format})", true] : ["POST to #{action['endpoint']} failed", false]
    end

    def webhook_body(format:, message:)
      case format
      when 'slack' then [JSON.generate({ 'text' => message }), 'application/json']
      when 'discord' then [JSON.generate({ 'content' => message }), 'application/json']
      when 'ntfy', 'raw' then [message, 'text/plain']
      else
        envelope = { 'message' => message, 'rule' => @rule_id, 'trigger' => @trigger_desc, 'at' => Sys.now_iso }
        [JSON.generate(envelope), 'application/json']
      end
    end

    def apply_notify(action)
      sanitize = ->(text) { text.to_s.gsub(/[[:cntrl:]]/, '').sub(/\A-+/, '') }
      message = sanitize.call(template_message(message: action['message']))
      title = sanitize.call(action.fetch('title', 'Omaflow'))
      Sys.notify(title.empty? ? 'Omaflow' : title, message.empty? ? '·' : message)
      [message, true]
    end

    def template_message(message:)
      values = @trigger_data.transform_keys(&:to_s).merge('trigger' => @trigger_desc.to_s)
      replacements = []
      rendered = message.scan(/\{\{([^{}]*)\}\}/).flatten.uniq.each_with_index.reduce(message) do |text, (key, index)|
        token = "\0#{index}\0"
        replacements << [token, values.fetch(key, '').to_s]
        Sys.subst(text, "{{#{key}}}", token)
      end
      replacements.reduce(rendered) { |text, (token, value)| Sys.subst(text, token, value) }
    end
  end
end
