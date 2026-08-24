# frozen_string_literal: true

module Omaflow
  class Validator
    HHMM = /\A([01][0-9]|2[0-3]):[0-5][0-9]\z/
    SLUG = /\A[a-z0-9][a-z0-9-]{0,40}\z/
    SHORT_SLUG = /\A[a-z0-9][a-z0-9-]{0,30}\z/

    TRIGGER_CHECKS = {
      'manual' => :check_manual_trigger,
      'time' => :check_time_trigger,
      'interval' => :check_interval_trigger,
      'lid-opened' => :check_lid_trigger,
      'lid-closed' => :check_lid_trigger,
      'monitor-connected' => :check_monitor_trigger,
      'monitor-disconnected' => :check_monitor_trigger,
      'app-opened' => :check_app_trigger,
      'app-closed' => :check_app_trigger,
      'wifi-connected' => :check_wifi_connected_trigger,
      'wifi-disconnected' => :check_wifi_disconnected_trigger,
      'power-source' => :check_power_trigger,
      'custom' => :check_custom_trigger
    }.freeze

    CONDITION_CHECKS = {
      'time-between' => :check_time_between,
      'weekday' => :check_weekday,
      'on-power' => :check_on_power,
      'lid-state' => :check_lid_state,
      'monitor-present' => :check_monitor_present,
      'app-running' => :check_app_running,
      'on-ssid' => :check_on_ssid
    }.freeze

    ACTION_CHECKS = {
      'theme' => :check_theme,
      'dnd' => :check_state_action,
      'nightlight' => :check_state_action,
      'stay-awake' => :check_state_action,
      'launch' => :check_launch,
      'workspace' => :check_workspace,
      'audio-output' => :check_audio_output,
      'script' => :check_script,
      'webhook' => :check_webhook,
      'notify' => :check_notify
    }.freeze

    attr_reader :errors, :warnings

    def self.validate_file(path)
      rule = JSON.parse(Store.safe_read(path))
      return [['not a JSON object'], []] unless rule.is_a?(Hash)

      new(rule).validate
    rescue StandardError
      [['not a JSON object'], []]
    end

    def initialize(rule)
      @rule = rule
      @errors = []
      @warnings = []
    end

    def validate
      check_top_level
      check_trigger
      check_conditions
      check_actions
      [errors, warnings]
    end

    private

    def err(message) = errors << message
    def warn(message) = warnings << message

    def safe_str?(value, max: 200)
      value.is_a?(String) && value.length.between?(1, max) &&
        value.codepoints.all? { it >= 32 } && !value.start_with?('-')
    end

    def integer_between?(value, range) = value.is_a?(Integer) && range.cover?(value)

    def unknown_keys(object, allowed, label)
      extra = object.keys - allowed
      err("unknown field in #{label}: #{extra.join(', ')}") unless extra.empty?
    end

    def check_top_level
      err('schemaVersion must be 1') unless @rule['schemaVersion'] == 1
      err('id must be a lowercase slug') unless @rule['id'].is_a?(String) && @rule['id'].match?(SLUG)
      err('name must be a plain string (max 80, no leading dash or control chars)') unless safe_str?(@rule['name'], max: 80)
      err('enabled must be a boolean') unless [true, false].include?(@rule['enabled'])
      err('trigger must be an object') unless @rule['trigger'].is_a?(Hash)
      err('actions must be a non-empty array (max 10)') unless @rule['actions'].is_a?(Array) && @rule['actions'].size.between?(1, 10)
      conditions = @rule.fetch('conditions', [])
      err('conditions must be an array (max 5)') unless conditions.is_a?(Array) && conditions.size <= 5
      cooldown = @rule.fetch('cooldownSeconds', 60)
      err('cooldownSeconds must be an integer 0..86400') unless integer_between?(cooldown, 0..86_400)
      source = @rule.fetch('source', '')
      err('source must be a string (max 500)') unless source.is_a?(String) && source.length <= 500
      extra = @rule.keys - Vocabulary::RULE_FIELDS
      err("unknown top-level field: #{extra.join(', ')}") unless extra.empty?
    end

    def check_trigger
      trigger = @rule['trigger']
      return unless trigger.is_a?(Hash)

      type = trigger['type'].to_s
      return err('trigger.type is required') if type.empty?

      check = TRIGGER_CHECKS[type]
      return err("unknown trigger type: #{type}") unless check

      send(check, trigger)
    end

    def check_manual_trigger(trigger) = unknown_keys(trigger, %w[type], '.trigger')

    def check_time_trigger(trigger)
      err('time trigger needs at: "HH:MM"') unless trigger['at'].is_a?(String) && trigger['at'].match?(HHMM)
      days = trigger.fetch('days', Vocabulary::WEEKDAYS)
      err('time trigger days must be from mon..sun') unless days.is_a?(Array) && !days.empty? && (days - Vocabulary::WEEKDAYS).empty?
      unknown_keys(trigger, %w[type at days], '.trigger')
    end

    def check_interval_trigger(trigger)
      err('interval trigger needs minutes as an integer 1..1440') unless integer_between?(trigger['minutes'], 1..1440)
      unknown_keys(trigger, %w[type minutes], '.trigger')
    end

    def check_lid_trigger(trigger)
      unknown_keys(trigger, %w[type], '.trigger')
      warn_lid_unavailable
    end

    def check_monitor_trigger(trigger)
      match = trigger['match']
      target = match.is_a?(Hash) ? match['description'] || match['name'] : nil
      err("#{trigger['type']} needs match.description or match.name as a plain string") unless safe_str?(target)
      unknown_keys(trigger, %w[type match], '.trigger')
      unknown_keys(match, %w[description name], '.trigger.match') if match.is_a?(Hash)
    end

    def check_app_trigger(trigger)
      match = trigger['match']
      target = match.is_a?(Hash) ? match['class'] || match['title'] : nil
      err("#{trigger['type']} needs match.class or match.title as a plain string") unless safe_str?(target)
      unknown_keys(trigger, %w[type match], '.trigger')
      unknown_keys(match, %w[class title], '.trigger.match') if match.is_a?(Hash)
    end

    def check_wifi_connected_trigger(trigger)
      match = trigger['match']
      valid = match.is_a?(Hash) && (match['ssid'] == '*' || safe_str?(match['ssid']) || match['known'] == false)
      valid &&= match['ssid'] == '*' || safe_str?(match['ssid']) if match.is_a?(Hash) && match.key?('ssid')
      err('wifi-connected needs match.ssid ("*" for any) or match.known: false') unless valid
      unknown_keys(trigger, %w[type match], '.trigger')
      unknown_keys(match, %w[ssid known], '.trigger.match') if match.is_a?(Hash)
    end

    def check_wifi_disconnected_trigger(trigger) = unknown_keys(trigger, %w[type], '.trigger')

    def check_power_trigger(trigger)
      err('power-source needs source: ac|battery') unless %w[ac battery].include?(trigger['source'])
      unknown_keys(trigger, %w[type source], '.trigger')
    end

    def check_custom_trigger(trigger)
      err('custom trigger needs name as a lowercase slug') unless trigger['name'].is_a?(String) && trigger['name'].match?(SLUG)
      unknown_keys(trigger, %w[type name], '.trigger')
    end

    def check_conditions
      conditions = @rule.fetch('conditions', [])
      return unless conditions.is_a?(Array)

      conditions.each do |condition|
        type = condition.is_a?(Hash) ? condition['type'].to_s : ''
        check = CONDITION_CHECKS[type]
        next err("unknown condition type: #{type}") unless check

        send(check, condition)
      end
    end

    def check_time_between(condition)
      valid = condition['from'].to_s.match?(HHMM) && condition['to'].to_s.match?(HHMM)
      err('time-between needs from/to as HH:MM') unless valid
      unknown_keys(condition, %w[type from to], 'time-between condition')
    end

    def check_weekday(condition)
      days = condition.fetch('days', [])
      err('weekday needs days from mon..sun') unless days.is_a?(Array) && !days.empty? && (days - Vocabulary::WEEKDAYS).empty?
      unknown_keys(condition, %w[type days], 'weekday condition')
    end

    def check_on_power(condition)
      err('on-power needs source: ac|battery') unless %w[ac battery].include?(condition['source'])
      unknown_keys(condition, %w[type source], 'on-power condition')
    end

    def check_lid_state(condition)
      err('lid-state needs state: open|closed') unless %w[open closed].include?(condition['state'])
      unknown_keys(condition, %w[type state], 'lid-state condition')
      warn_lid_unavailable
    end

    def warn_lid_unavailable
      message = 'no laptop lid state is currently available; this rule will stay idle'
      warn(message) unless lid_available? || warnings.include?(message)
    end

    def lid_available?
      lid_dir = ENV.fetch('OMAFLOW_LID_DIR', '/proc/acpi/button/lid')
      Dir.glob(File.join(lid_dir, '*', 'state')).any? { File.file?(it) && File.readable?(it) }
    rescue StandardError
      false
    end

    def check_monitor_present(condition)
      match = condition['match']
      target = match.is_a?(Hash) ? match['description'] || match['name'] : nil
      err('monitor-present needs a plain-string match') unless safe_str?(target)
      unknown_keys(condition, %w[type match], 'monitor-present condition')
      unknown_keys(match, %w[description name], 'monitor-present condition match') if match.is_a?(Hash)
    end

    def check_app_running(condition)
      match = condition['match']
      target = match.is_a?(Hash) ? match['class'] || match['title'] : nil
      err('app-running needs match.class or match.title as a plain string') unless safe_str?(target)
      unknown_keys(condition, %w[type match], 'app-running condition')
      unknown_keys(match, %w[class title], 'app-running condition match') if match.is_a?(Hash)
    end

    def check_on_ssid(condition)
      err('on-ssid needs a plain-string ssid') unless safe_str?(condition['ssid'])
      unknown_keys(condition, %w[type ssid], 'on-ssid condition')
    end

    def check_actions
      actions = @rule.fetch('actions', [])
      return unless actions.is_a?(Array)

      actions.each do |action|
        type = action.is_a?(Hash) ? action['type'].to_s : ''
        next err('action missing type') if type.empty?

        check = ACTION_CHECKS[type]
        next err("unknown action type: #{type}") unless check

        send(check, action)
      end
    end

    def installed_themes
      @installed_themes ||= begin
        output, ok = Sys.capture('omarchy', 'theme', 'list')
        ok ? output.lines(chomp: true).reject(&:empty?) : nil
      end
    end

    def check_theme(action)
      return err('theme action needs a plain-string name') unless safe_str?(action['name'])

      unknown_keys(action, %w[type name], "#{action['type']} action")
      themes = installed_themes
      return if themes.nil? || themes.any? { it.casecmp?(action['name']) }

      err("theme not installed: #{action['name']} (omarchy theme list)")
    end

    def check_state_action(action)
      err("#{action['type']} needs state: on|off") unless %w[on off].include?(action['state'])
      unknown_keys(action, %w[type state], "#{action['type']} action")
    end

    def check_launch(action)
      return err('launch action needs a plain-string app') unless safe_str?(action['app'])

      unknown_keys(action, %w[type app workspace], 'launch action')
      err("no desktop entry found for app: #{action['app']}") unless Desktop.resolve(action['app'])
      return unless action.key?('workspace')

      err('launch workspace must be an integer 1..10') unless integer_between?(action['workspace'], 1..10)
    end

    def check_workspace(action)
      err('workspace needs an integer number 1..10') unless integer_between?(action['number'], 1..10)
      unknown_keys(action, %w[type number], 'workspace action')
    end

    def check_audio_output(action)
      return err('audio-output needs a plain-string match') unless safe_str?(action['match'])

      unknown_keys(action, %w[type match], 'audio-output action')
      return unless Sys.which('pactl')

      output, ok = Sys.capture('pactl', '--format=json', 'list', 'sinks')
      return unless ok

      sinks = begin
        JSON.parse(output)
      rescue StandardError
        []
      end
      present = sinks.any? { "#{it['description']} #{it['name']}".downcase.include?(action['match'].downcase) }
      warn("no currently connected sink matches: #{action['match']} (may appear later)") unless present
    end

    def check_script(action)
      name = action['name']
      err('script action needs a lowercase allowlisted name') unless ScriptRegistry.valid_name?(name)
      unknown_keys(action, %w[type name], 'script action')
      return unless ScriptRegistry.valid_name?(name)

      if ScriptRegistry.entry(name).nil?
        err("no script named '#{name}' — add it with: omaflow scripts add #{name} /absolute/path")
      elsif ScriptRegistry.resolve(name).nil?
        err("script '#{name}' is unavailable or not safely executable")
      elsif ScriptRegistry.available(name).nil?
        err("script '#{name}' requires a compatible service that is not available")
      end
    end

    def check_webhook(action)
      unless action['endpoint'].is_a?(String) && action['endpoint'].match?(SHORT_SLUG)
        err('webhook needs endpoint as a short lowercase slug')
      end
      err('webhook needs a plain-string message (max 400, no leading dash or control chars)') unless safe_str?(action['message'], max: 400)
      unknown_keys(action, %w[type endpoint message], 'webhook action')
      endpoint = action['endpoint'].to_s
      return if endpoint.empty? || Store.read_json(Paths.webhooks_file, {}).key?(endpoint)

      err("no webhook endpoint named '#{endpoint}' — add it with: omaflow webhooks add #{endpoint} <url> [format]")
    end

    def check_notify(action)
      err('notify needs a plain-string message (no leading dash or control chars)') unless safe_str?(action['message'])
      err('notify title must be a plain string (max 60, no leading dash)') if action.key?('title') && !safe_str?(action['title'], max: 60)
      unknown_keys(action, %w[type title message], 'notify action')
    end
  end
end
