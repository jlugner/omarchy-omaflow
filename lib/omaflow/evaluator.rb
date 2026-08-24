# frozen_string_literal: true

module Omaflow
  class Evaluator
    INBOX_LIMIT = 20
    EVENT_DATA_LIMIT = 10
    EVENT_BYTES_LIMIT = 16_384

    def self.tick(reason = 'tick')
      Store.with_lock('.eval.lock', wait: false) { new(reason).tick }
      0
    end

    def initialize(reason)
      @reason = reason
    end

    def tick
      custom_events = drain_inbox
      @now = Time.now
      @minute = @now.strftime('%H:%M')
      @weekday = @now.strftime('%a').downcase
      @previous = previous_domains
      @probes = probe_domains
      @current = (@previous || {}).merge(@probes)
      Store.write_json(Paths.domains_file, @current)
      if @previous.nil?
        baseline
      else
        custom_events.concat(derive_events)
      end

      custom_events.each { fire_matching_rules(it) }
    end

    private

    def drain_inbox
      events = []
      candidates = 0
      Dir.each_child(Paths.inbox_dir) do |entry|
        next if entry.start_with?('.')

        path = File.join(Paths.inbox_dir, entry)
        next if File.lstat(path).directory?

        candidates += 1
        event = read_custom_event(path) if candidates <= INBOX_LIMIT
        events << event if event
        discard_inbox_file(path:)
      rescue StandardError
        discard_inbox_file(path:) if path
      end
      events
    rescue StandardError
      events
    end

    def discard_inbox_file(path:)
      File.unlink(path)
    rescue StandardError
      nil
    end

    def read_custom_event(path)
      payload = JSON.parse(Store.safe_read(path, max_bytes: EVENT_BYTES_LIMIT))
      return unless payload.instance_of?(Hash) && payload.keys.sort == %w[at data name]
      return unless payload['name'].is_a?(String) && payload['name'].match?(Validator::SLUG)
      return unless payload['data'].instance_of?(Hash) && safe_event_string?(payload['at'])

      data = payload['data'].each_with_object({}) do |(key, value), sanitized|
        next unless safe_event_string?(key) && safe_event_string?(value)
        next if sanitized.size >= EVENT_DATA_LIMIT

        sanitized[key] = value
      end
      { 'type' => 'custom', 'data' => { 'name' => payload['name'] }.merge(data) }
    rescue StandardError
      nil
    end

    def safe_event_string?(value)
      value.is_a?(String) && value.bytesize.between?(1, 200) && !value.match?(/[[:cntrl:]]/) && !value.start_with?('-')
    end

    def previous_domains
      return nil unless File.exist?(Paths.domains_file)

      domains = Store.read_json(Paths.domains_file, {})
      return domains unless domains.empty?

      File.rename(Paths.domains_file, "#{Paths.domains_file}.corrupt")
      nil
    rescue StandardError
      nil
    end

    def probe_domains
      probes = { 'minute' => @minute }
      monitors = probe_monitors
      probes['monitors'] = monitors if monitors
      ssid = probe_ssid
      probes['ssid'] = ssid if ssid
      on_ac = probe_on_ac
      probes['onAc'] = on_ac unless on_ac.nil?
      lid_closed = probe_lid_closed
      probes['lidClosed'] = lid_closed unless lid_closed.nil?
      probes
    end

    def probe_monitors
      output, ok = Sys.capture('hyprctl', 'monitors', '-j')
      parsed = begin
        JSON.parse(output) if ok
      rescue StandardError
        nil
      end
      return nil unless parsed.is_a?(Array)

      parsed.map { { 'name' => it['name'], 'description' => it['description'] } }
    end

    def probe_ssid
      output, ok = Sys.capture('nmcli', '-t', '-f', 'ACTIVE,SSID', 'dev', 'wifi')
      return nil unless ok

      output.lines(chomp: true).find { it.start_with?('yes:') }&.delete_prefix('yes:').to_s
    end

    def probe_on_ac
      power_dir = ENV.fetch('OMAFLOW_POWER_DIR', '/sys/class/power_supply')
      mains = Dir.glob(File.join(power_dir, '*', 'type')).find do |path|
        File.read(path, 64).to_s.strip == 'Mains'
      rescue StandardError
        false
      end
      return nil unless mains

      online = File.read(File.join(File.dirname(mains), 'online'), 64).to_s.strip
      { '1' => true, '0' => false }[online]
    rescue StandardError
      nil
    end

    def probe_lid_closed
      lid_dir = ENV.fetch('OMAFLOW_LID_DIR', '/proc/acpi/button/lid')
      Dir.glob(File.join(lid_dir, '*', 'state')).each do |path|
        state = File.read(path, 64).to_s.downcase
        return true if state.include?('closed')
        return false if state.include?('open')
      rescue StandardError
        next
      end
      nil
    end

    def baseline
      seed_seen_ssid
      Store.reindex
    end

    def seed_seen_ssid
      ssid = @current['ssid'].to_s
      return if ssid.empty?

      seen = Store.read_json(Paths.seen_ssids_file, [])
      Store.write_json(Paths.seen_ssids_file, (seen + [ssid]).uniq)
    end

    def domain_fresh?(key) = @previous.key?(key) && @probes.key?(key)

    def derive_events
      [*monitor_events, *wifi_events, *power_events, *lid_events, *time_events]
    end

    def monitor_events
      return [] unless domain_fresh?('monitors')

      previous_names = @previous['monitors'].map { it['name'] }
      current_names = @current['monitors'].map { it['name'] }
      added = @current['monitors'].reject { previous_names.include?(it['name']) }
      removed = @previous['monitors'].reject { current_names.include?(it['name']) }
      added.map { { 'type' => 'monitor-connected', 'data' => it } } +
        removed.map { { 'type' => 'monitor-disconnected', 'data' => it } }
    end

    def wifi_events
      return [] unless domain_fresh?('ssid')

      previous_ssid = @previous['ssid'].to_s
      current_ssid = @current['ssid']
      return [] if previous_ssid == current_ssid

      events = []
      events << { 'type' => 'wifi-disconnected', 'data' => { 'ssid' => previous_ssid } } unless previous_ssid.empty?
      unless current_ssid.empty?
        seen = Store.read_json(Paths.seen_ssids_file, [])
        events << { 'type' => 'wifi-connected', 'data' => { 'ssid' => current_ssid, 'known' => seen.include?(current_ssid) } }
        Store.write_json(Paths.seen_ssids_file, (seen + [current_ssid]).uniq)
      end
      events
    end

    def power_events
      return [] unless domain_fresh?('onAc')
      return [] if @previous['onAc'] == @current['onAc']

      [{ 'type' => 'power-source', 'data' => { 'source' => @current['onAc'] ? 'ac' : 'battery' } }]
    end

    def lid_events
      return [] unless domain_fresh?('lidClosed')
      return [] if @previous['lidClosed'] == @current['lidClosed']

      type = @current['lidClosed'] ? 'lid-closed' : 'lid-opened'
      [{ 'type' => type, 'data' => { 'state' => @current['lidClosed'] ? 'closed' : 'open' } }]
    end

    def time_events
      return [] if @previous['minute'] == @current['minute']

      [{ 'type' => 'time', 'data' => { 'at' => @current['minute'] } },
       { 'type' => 'interval', 'data' => { 'at' => @current['minute'] } }]
    end

    def fire_matching_rules(event)
      Store.rules.each do |rule|
        next unless rule['enabled'] == true
        next unless rule.dig('trigger', 'type') == event['type']
        next unless trigger_matches?(rule, event)
        next unless conditions_pass?(rule)
        next unless cooldown_over?(rule)

        Executor.run(rule['id'], trigger: trigger_description(event), trigger_data: event['data'], respect_cooldown: true)
      rescue StandardError => e
        Store.log_append({ 'at' => Sys.now_iso, 'kind' => 'error', 'ruleId' => rule['id'],
                           'status' => 'error', 'detail' => "#{e.class}: #{e.message}" })
      end
    end

    def trigger_description(event)
      pairs = event['data'].to_a.map { |key, value| "#{key}=#{value}" }.join(' ')
      "#{event['type']} #{pairs} (#{@reason})".squeeze(' ')
    end

    def trigger_matches?(rule, event)
      trigger = rule['trigger']
      data = event['data'] || {}
      case event['type']
      when 'monitor-connected', 'monitor-disconnected'
        target = (trigger.dig('match', 'description') || trigger.dig('match', 'name')).to_s.downcase
        "#{data['description']} #{data['name']}".downcase.include?(target)
      when 'wifi-connected'
        match = trigger['match'] || {}
        if match['known'] == false then data['known'] == false
        elsif match['ssid'] == '*' then true
        else data['ssid'].to_s.downcase.include?(match['ssid'].to_s.downcase)
        end
      when 'power-source' then data['source'] == trigger['source']
      when 'time' then data['at'] == trigger['at'] && trigger_days(trigger).include?(@weekday)
      when 'interval' then interval_elapsed?(rule)
      when 'custom' then data['name'] == trigger['name']
      else true
      end
    end

    def interval_elapsed?(rule)
      last = Store.read_json(Paths.cooldowns_file, {}).dig(rule['id'], 'lastFiredEpoch').to_i
      @now.to_i - last >= rule.dig('trigger', 'minutes').to_i * 60
    end

    def trigger_days(trigger) = trigger.fetch('days', Vocabulary::WEEKDAYS)

    def conditions_pass?(rule)
      rule.fetch('conditions', []).all? { condition_passes?(it) }
    end

    def condition_passes?(condition)
      case condition['type']
      when 'time-between' then time_between?(condition['from'], condition['to'])
      when 'weekday' then condition.fetch('days', []).include?(@weekday)
      when 'on-power' then (condition['source'] == 'ac') == @current.fetch('onAc', true)
      when 'lid-state' then lid_state?(condition['state'])
      when 'monitor-present' then monitor_present?(condition)
      when 'on-ssid' then @current['ssid'].to_s.downcase.include?(condition['ssid'].to_s.downcase)
      else false
      end
    end

    def time_between?(from, to)
      if from <= to
        @minute.between?(from, to)
      else
        @minute >= from || @minute <= to
      end
    end

    def monitor_present?(condition)
      target = (condition.dig('match', 'description') || condition.dig('match', 'name')).to_s.downcase
      @current.fetch('monitors', []).any? { "#{it['description']} #{it['name']}".downcase.include?(target) }
    end

    def lid_state?(state)
      return false unless @current.key?('lidClosed')

      @current['lidClosed'] == (state == 'closed')
    end

    def cooldown_over?(rule)
      last = Store.read_json(Paths.cooldowns_file, {}).dig(rule['id'], 'lastFiredEpoch').to_i
      Time.now.to_i - last >= rule.fetch('cooldownSeconds', 60)
    end
  end
end
