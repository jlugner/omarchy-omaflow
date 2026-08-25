# frozen_string_literal: true

require 'json'

module Omaflow
  module Store
    module_function

    MAX_JSON_BYTES = 262_144
    MAX_RULE_FILES = 200
    WATCH_DIR_LIMIT = 8
    GIT_REPO_LIMIT = 8
    INOTIFY_DIR_LIMIT = WATCH_DIR_LIMIT + GIT_REPO_LIMIT

    def safe_read(path, max_bytes: MAX_JSON_BYTES)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        raise IOError, "not a regular file: #{path}" unless stat.file?
        raise IOError, "file exceeds #{max_bytes} bytes: #{path}" if stat.size > max_bytes

        file.read(max_bytes).to_s.force_encoding(Encoding::UTF_8)
      end
    end

    def read_json(path, fallback)
      parse_json(safe_read(path), fallback)
    rescue StandardError
      fallback
    end

    def parse_json(text, fallback)
      parsed = JSON.parse(text)
      parsed.instance_of?(fallback.class) ? parsed : fallback
    rescue StandardError
      fallback
    end

    def load_json!(path, expected)
      parsed = JSON.parse(safe_read(path))
      raise JSON::ParserError, "#{path} is not a JSON #{expected.class.name.downcase}" unless parsed.instance_of?(expected.class)

      parsed
    end

    def write_json(path, value)
      Paths.ensure_dirs
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{rand(1_000_000)}")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { it.puts(JSON.generate(value)) }
      File.rename(tmp, path)
    end

    def install_json(path, value)
      Paths.ensure_dirs
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{rand(1_000_000)}")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { it.puts(JSON.generate(value)) }
      File.link(tmp, path)
      true
    rescue Errno::EEXIST
      false
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def with_lock(name, wait: true, timeout: 90)
      Paths.ensure_dirs
      File.open(File.join(Paths.state_dir, name), File::CREAT | File::WRONLY | File::NOFOLLOW, 0o644) do |file|
        if wait
          deadline = Time.now + timeout
          until file.flock(File::LOCK_EX | File::LOCK_NB)
            return false if Time.now > deadline

            sleep 0.2
          end
        else
          return false unless file.flock(File::LOCK_EX | File::LOCK_NB)
        end
        yield
        true
      end
    end

    def safe_append(path)
      File.open(path, File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW, 0o600) do |file|
        raise IOError, "not a regular file: #{path}" unless file.stat.file?

        yield file
      end
    rescue Errno::ELOOP
      File.unlink(path)
      File.open(path, File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW, 0o600) { yield it }
    end

    def log_append(entry)
      with_lock('.log.lock') do
        safe_append(Paths.log_file) { it.puts(JSON.generate(entry)) }
        lines = begin
          safe_read(Paths.log_file, max_bytes: 4_194_304).lines
        rescue StandardError
          nil
        end
        if lines.nil? || lines.size > 500
          tmp = "#{Paths.log_file}.#{Process.pid}"
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { it.write((lines || []).last(400).join) }
          File.rename(tmp, Paths.log_file)
        end
      end
    end

    def rules
      names = []
      Dir.each_child(Paths.rules_dir) do |name|
        next unless name.end_with?('.json')

        names << name
        break if names.size >= MAX_RULE_FILES
      end
      names.sort.filter_map do |name|
        path = File.join(Paths.rules_dir, name)
        rule = read_json(path, {})
        rule.empty? ? nil : rule
      end
    end

    def armed = read_json(Paths.armed_file, {})

    def arm(rule_id)
      at = Sys.now_iso
      mutate_armed do |rules|
        rules[rule_id] = { 'armedAt' => at, 'armedEpoch' => Time.now.to_i }
        true
      end
      log_append({ 'at' => at, 'kind' => 'armed', 'ruleId' => rule_id, 'status' => 'ok' })
      reindex
    end

    def disarm(rule_id, log: false)
      removed = mutate_armed { it.delete(rule_id) }
      return unless removed

      log_append({ 'at' => Sys.now_iso, 'kind' => 'disarmed', 'ruleId' => rule_id, 'status' => 'ok' }) if log
      reindex
      removed
    end

    def mutate_armed
      result = false
      locked = with_lock('.armed.lock') do
        rules = File.exist?(Paths.armed_file) ? load_json!(Paths.armed_file, {}) : {}
        result = yield rules
        write_json(Paths.armed_file, rules) if result
      end
      raise IOError, 'Armed state is busy' unless locked

      result
    end

    def reindex
      cooldowns = read_json(Paths.cooldowns_file, {})
      armed_rules = armed
      loaded_rules = rules
      generated_at = Sys.now_iso
      indexed = loaded_rules.map { index_entry(it, cooldowns, armed_rules) }
      write_json(Paths.index_file, { 'generatedAt' => generated_at, 'rules' => indexed.sort_by { it['name'].to_s } })
      write_json(Paths.watched_dirs_file, { 'generatedAt' => generated_at, 'dirs' => watched_dirs(loaded_rules, armed_rules) })
    end

    def watched_dirs(loaded_rules, armed_rules = armed)
      (file_trigger_dirs(loaded_rules, armed_rules) + git_repos(loaded_rules, armed_rules).filter_map { GitState.git_dir(it) })
        .sort.uniq.first(INOTIFY_DIR_LIMIT)
    end

    def file_trigger_dirs(loaded_rules, armed_rules = armed)
      loaded_rules.flat_map { active_triggers(it, armed_rules) }.filter_map do |trigger|
        next unless %w[file-created folder-created].include?(trigger['type']) && trigger['path'].is_a?(String)

        safe_expand_path(trigger['path'])
      end.sort.uniq.first(WATCH_DIR_LIMIT)
    end

    def git_repos(loaded_rules, armed_rules = armed)
      loaded_rules.flat_map do |rule|
        conditions = rule['conditions'].is_a?(Array) ? rule['conditions'].grep(Hash) : []
        paths = active_triggers(rule, armed_rules).filter_map do |trigger|
          trigger['repo'] if trigger['type'] == 'git-branch-changed' && trigger['repo'].is_a?(String)
        end
        if rule['enabled'] == true
          conditions.each do |condition|
            paths << condition['repo'] if condition['type'] == 'on-branch' && condition['repo'].is_a?(String)
          end
        end
        paths.filter_map { safe_expand_path(it) }
      end.sort.uniq.first(GIT_REPO_LIMIT)
    end

    def active_triggers(rule, armed_rules)
      triggers = []
      triggers << rule['trigger'] if rule['enabled'] == true && rule['trigger'].is_a?(Hash)
      until_block = rule['until'].is_a?(Hash) ? rule['until'] : {}
      until_trigger = until_block['trigger']
      triggers << until_trigger if armed_rules.key?(rule['id']) && until_trigger.is_a?(Hash)
      triggers
    end

    def safe_expand_path(path)
      File.expand_path(path)
    rescue StandardError
      nil
    end

    def index_entry(rule, cooldowns, armed_rules = armed)
      trigger = rule['trigger'].is_a?(Hash) ? rule['trigger'] : {}
      actions = rule['actions'].is_a?(Array) ? rule['actions'].grep(Hash) : []
      conditions = rule['conditions'].is_a?(Array) ? rule['conditions'] : []
      {
        'id' => rule['id'].to_s,
        'name' => rule['name'].is_a?(String) ? rule['name'] : rule['id'].to_s,
        'enabled' => rule['enabled'] == true,
        'triggerSummary' => trigger_summary(trigger),
        'actionsSummary' => actions.map { it['type'].to_s }.join(', '),
        'actionCount' => actions.size,
        'conditionCount' => conditions.size,
        'armed' => armed_rules.key?(rule['id']),
        'source' => rule['source'].to_s,
        'lastFired' => cooldowns.dig(rule['id'], 'lastFiredAt').to_s
      }
    end

    def trigger_summary(trigger)
      match = trigger['match'].is_a?(Hash) ? trigger['match'] : {}
      suffix =
        if match['description'] then ": #{match['description']}"
        elsif match['class'] then ": #{match['class']}"
        elsif match['title'] then ": #{match['title']}"
        elsif trigger['path'] then ": #{trigger['path']}"
        elsif trigger['repo'] then ": #{trigger['repo']}"
        elsif match['name'] then ": #{match['name']}"
        elsif match['ssid'] then ": #{match['ssid']}"
        elsif match['known'] == false then ': unknown network'
        elsif trigger['at'] then " #{trigger['at']}"
        elsif trigger['minutes'] then " every #{trigger['minutes']}m"
        elsif trigger['source'] then ": #{trigger['source']}"
        elsif trigger['name'] then ": #{trigger['name']}"
        else ''
        end
      "#{trigger['type'] || '?'}#{suffix}"
    end
  end
end
