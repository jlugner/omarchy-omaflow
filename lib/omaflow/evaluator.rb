# frozen_string_literal: true

module Omaflow
  class Evaluator
    INBOX_LIMIT = 20
    EVENT_DATA_LIMIT = 10
    EVENT_BYTES_LIMIT = 16_384
    INBOX_SCAN_LIMIT = 256
    MONITOR_LIMIT = 16
    WINDOW_LIMIT = 100
    WINDOW_EVENT_LIMIT = 10
    WATCH_DIR_LIMIT = Store::WATCH_DIR_LIMIT
    GIT_REPO_LIMIT = Store::GIT_REPO_LIMIT
    FILE_ENTRY_LIMIT = 512
    FILE_EVENT_LIMIT = 10

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
      @rules = Store.rules
      @file_trigger_dirs = Store.file_trigger_dirs(@rules).first(WATCH_DIR_LIMIT)
      @file_keys = @file_trigger_dirs.map { file_probe_key(it) }
      @git_repos = Store.git_repos(@rules).first(GIT_REPO_LIMIT)
      @git_keys = @git_repos.map { git_probe_key(it) }
      @watched_dirs = Store.watched_dirs(@rules)
      sync_watched_dirs
      @probes = probe_domains
      @current = current_domains
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
      candidates = []
      Dir.each_child(Paths.inbox_dir) do |entry|
        candidates << entry
        break if candidates.size >= INBOX_SCAN_LIMIT
      end
      candidates.sort.reject { inbox_entry_ignored?(it) }.first(INBOX_LIMIT).each do |entry|
        path = File.join(Paths.inbox_dir, entry)
        event = read_custom_event(path)
        events << event if event
        discard_inbox_file(path:)
      end
      events
    rescue StandardError
      events
    end

    def inbox_entry_ignored?(entry)
      entry.start_with?('.') || File.lstat(File.join(Paths.inbox_dir, entry)).directory?
    rescue StandardError
      false
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
      { 'type' => 'custom', 'data' => data.merge('name' => payload['name'], 'at' => payload['at']) }
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
      windows = probe_windows
      probes['windows'] = windows if windows
      @file_trigger_dirs.each do |path|
        files = probe_directory(path)
        probes[file_probe_key(path)] = files if files
      end
      @git_repos.each do |repo|
        branch = GitState.current_branch(repo)
        probes[git_probe_key(repo)] = { 'branch' => branch } if branch
      end
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
      return nil unless parsed.is_a?(Array) && parsed.size <= MONITOR_LIMIT
      return nil unless parsed.all? { it.is_a?(Hash) && it['name'].is_a?(String) && it['description'].is_a?(String) }

      parsed.map do |monitor|
        { 'name' => clean_probe_string(monitor['name']), 'description' => clean_probe_string(monitor['description']) }
      end
    end

    def probe_windows
      output, ok = Sys.capture('hyprctl', 'clients', '-j')
      parsed = begin
        JSON.parse(output) if ok
      rescue StandardError
        nil
      end
      return nil unless parsed.is_a?(Array) && parsed.size <= WINDOW_LIMIT && parsed.all?(Hash)

      parsed.map do |window|
        { 'address' => window['address'], 'class' => clean_probe_string(window['class'].to_s),
          'title' => clean_probe_string(window['title'].to_s) }
      end
    rescue StandardError
      nil
    end

    def clean_probe_string(value) = value.gsub(/[[:cntrl:]]/, '')[0, 120]

    def probe_directory(path)
      entries = []
      count = 0
      Dir.each_child(path) do |name|
        count += 1
        return nil if count > FILE_ENTRY_LIMIT
        next if name.start_with?('.')

        entries << directory_entry(path, name)
      end
      entries.sort_by { [it['name'], it['dir'] ? 0 : 1] }
    rescue StandardError
      nil
    end

    def clean_file_name(value) = value.scrub.gsub(/[[:cntrl:]]/, '')[0, 200]

    def directory_entry(path, name)
      { 'name' => clean_file_name(name), 'dir' => File.lstat(File.join(path, name)).directory? }
    rescue StandardError
      { 'name' => clean_file_name(name), 'dir' => false }
    end

    def file_probe_key(path) = "files:#{path}"
    def git_probe_key(repo) = "git:#{repo}"

    def current_domains
      previous = (@previous || {}).reject do |key, _value|
        (key.start_with?('files:') && !@file_keys.include?(key)) || (key.start_with?('git:') && !@git_keys.include?(key))
      end
      previous.merge(@probes)
    end

    def sync_watched_dirs
      previous = Store.read_json(Paths.watched_dirs_file, {})
      return if previous['dirs'] == @watched_dirs

      Store.write_json(Paths.watched_dirs_file, { 'generatedAt' => Sys.now_iso, 'dirs' => @watched_dirs })
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
      [*monitor_events, *window_events, *file_events, *git_events, *wifi_events, *power_events, *lid_events, *time_events]
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

    def window_events
      return [] unless domain_fresh?('windows')

      previous_addresses = @previous['windows'].map { it['address'] }
      current_addresses = @current['windows'].map { it['address'] }
      added = @current['windows'].reject { previous_addresses.include?(it['address']) }
      removed = @previous['windows'].reject { current_addresses.include?(it['address']) }
      events = added.map { { 'type' => 'app-opened', 'data' => window_event_data(it) } } +
               removed.map { { 'type' => 'app-closed', 'data' => window_event_data(it) } }
      events.size > WINDOW_EVENT_LIMIT ? [] : events
    end

    def window_event_data(window) = { 'class' => window['class'], 'title' => window['title'] }

    def file_events
      @file_trigger_dirs.flat_map do |path|
        key = file_probe_key(path)
        next [] unless domain_fresh?(key)

        previous_names = @previous[key].map { it['name'] }
        added = @current[key].reject { previous_names.include?(it['name']) }
        next [] if added.size > FILE_EVENT_LIMIT

        added.map do |entry|
          type = entry['dir'] ? 'folder-created' : 'file-created'
          { 'type' => type, 'data' => { 'name' => entry['name'], 'path' => path } }
        end
      end
    end

    def git_events
      @git_repos.filter_map do |repo|
        key = git_probe_key(repo)
        next unless domain_fresh?(key)

        previous_branch = @previous.dig(key, 'branch')
        current_branch = @current.dig(key, 'branch')
        next if previous_branch == current_branch

        { 'type' => 'git-branch-changed',
          'data' => { 'repo' => repo, 'branch' => current_branch, 'from' => previous_branch } }
      end
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
      @rules.each do |rule|
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
      when 'app-opened', 'app-closed'
        app_matches?(trigger['match'], data)
      when 'wifi-connected'
        match = trigger['match'] || {}
        if match['known'] == false then data['known'] == false
        elsif match['ssid'] == '*' then true
        else data['ssid'].to_s.downcase.include?(match['ssid'].to_s.downcase)
        end
      when 'power-source' then data['source'] == trigger['source']
      when 'file-created', 'folder-created'
        file_trigger_matches?(trigger, data)
      when 'git-branch-changed'
        git_trigger_matches?(trigger, data)
      when 'time' then data['at'] == trigger['at'] && trigger_days(trigger).include?(@weekday)
      when 'interval' then interval_elapsed?(rule)
      when 'custom' then data['name'] == trigger['name']
      else true
      end
    end

    def file_trigger_matches?(trigger, data)
      return false unless data['path'] == File.expand_path(trigger['path'])

      name = trigger.dig('match', 'name')
      name.nil? || data['name'].to_s.downcase.include?(name.downcase)
    rescue StandardError
      false
    end

    def git_trigger_matches?(trigger, data)
      return false unless data['repo'] == File.expand_path(trigger['repo'])

      branch = trigger.dig('match', 'branch')
      branch.nil? || data['branch'].to_s.downcase.include?(branch.downcase)
    rescue StandardError
      false
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
      when 'app-running' then app_running?(condition)
      when 'on-branch' then on_branch?(condition)
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

    def app_running?(condition)
      return false unless @probes.key?('windows')

      @current['windows'].any? { app_matches?(condition['match'], it) }
    end

    def app_matches?(match, window)
      field = match.key?('class') ? 'class' : 'title'
      window[field].to_s.downcase.include?(match[field].to_s.downcase)
    end

    def on_branch?(condition)
      key = git_probe_key(File.expand_path(condition['repo']))
      return false unless @current.key?(key)

      @current.dig(key, 'branch').to_s.downcase.include?(condition['branch'].downcase)
    rescue StandardError
      false
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
