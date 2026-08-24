# frozen_string_literal: true

module Omaflow
  class Evaluator
    def self.tick(reason = 'tick')
      Store.with_lock('.eval.lock', wait: false) { new(reason).tick }
      0
    end

    def initialize(reason)
      @reason = reason
    end

    def tick
      @now = Time.now
      @minute = @now.strftime('%H:%M')
      @weekday = @now.strftime('%a').downcase
      @previous = previous_domains
      @probes = probe_domains
      @current = (@previous || {}).merge(@probes)
      Store.write_json(Paths.domains_file, @current)
      return baseline if @previous.nil?

      derive_events.each { fire_matching_rules(it) }
    end

    private

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
        File.read(path).strip == 'Mains'
      rescue StandardError
        false
      end
      return true unless mains

      online = File.read(File.join(File.dirname(mains), 'online')).strip
      { '1' => true, '0' => false }[online]
    rescue StandardError
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
      [*monitor_events, *wifi_events, *power_events, *time_events]
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

    def time_events
      return [] if @previous['minute'] == @current['minute']

      [{ 'type' => 'time', 'data' => { 'at' => @current['minute'] } }]
    end

    def fire_matching_rules(event)
      Store.rules.each do |rule|
        next unless rule['enabled'] == true
        next unless rule.dig('trigger', 'type') == event['type']
        next unless trigger_matches?(rule['trigger'], event)
        next unless conditions_pass?(rule)
        next unless cooldown_over?(rule)

        Executor.run(rule['id'], trigger: trigger_description(event), respect_cooldown: true)
      rescue StandardError => error
        Store.log_append({ 'at' => Sys.now_iso, 'kind' => 'error', 'ruleId' => rule['id'],
                           'status' => 'error', 'detail' => "#{error.class}: #{error.message}" })
      end
    end

    def trigger_description(event)
      pairs = event['data'].to_a.map { |key, value| "#{key}=#{value}" }.join(' ')
      "#{event['type']} #{pairs} (#{@reason})".squeeze(' ')
    end

    def trigger_matches?(trigger, event)
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
      else true
      end
    end

    def trigger_days(trigger) = trigger.fetch('days', Vocabulary::WEEKDAYS)

    def conditions_pass?(rule)
      rule.fetch('conditions', []).all? { condition_passes?(it) }
    end

    def condition_passes?(condition)
      case condition['type']
      when 'time-between' then time_between?(condition['from'], condition['to'])
      when 'weekday' then condition.fetch('days', []).include?(@weekday)
      when 'on-power' then (condition['source'] == 'ac') == @current['onAc']
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

    def cooldown_over?(rule)
      last = Store.read_json(Paths.cooldowns_file, {}).dig(rule['id'], 'lastFiredEpoch').to_i
      Time.now.to_i - last >= rule.fetch('cooldownSeconds', 60)
    end
  end
end
