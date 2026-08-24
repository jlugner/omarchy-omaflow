# frozen_string_literal: true

require 'json'

module Omaflow
  module Store
    module_function

    def read_json(path, fallback)
      parse_json(File.read(path), fallback)
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
      parsed = JSON.parse(File.read(path))
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
      File.open(File.join(Paths.state_dir, name), File::CREAT | File::WRONLY, 0o644) do |file|
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

    def log_append(entry)
      with_lock('.log.lock') do
        File.open(Paths.log_file, 'a', 0o600) { it.puts(JSON.generate(entry)) }
        lines = File.readlines(Paths.log_file)
        if lines.size > 500
          tmp = "#{Paths.log_file}.#{Process.pid}"
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { it.write(lines.last(400).join) }
          File.rename(tmp, Paths.log_file)
        end
      end
    end

    def rules
      Dir.glob(File.join(Paths.rules_dir, '*.json')).filter_map do |path|
        rule = read_json(path, {})
        rule.empty? ? nil : rule
      end
    end

    def reindex
      cooldowns = read_json(Paths.cooldowns_file, {})
      indexed = rules.map { index_entry(it, cooldowns) }
      write_json(Paths.index_file, { 'generatedAt' => Sys.now_iso, 'rules' => indexed.sort_by { it['name'].to_s } })
    end

    def index_entry(rule, cooldowns)
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
        'source' => rule['source'].to_s,
        'lastFired' => cooldowns.dig(rule['id'], 'lastFiredAt').to_s
      }
    end

    def trigger_summary(trigger)
      match = trigger['match'].is_a?(Hash) ? trigger['match'] : {}
      suffix =
        if match['description'] then ": #{match['description']}"
        elsif match['name'] then ": #{match['name']}"
        elsif match['ssid'] then ": #{match['ssid']}"
        elsif match['known'] == false then ': unknown network'
        elsif trigger['at'] then " #{trigger['at']}"
        elsif trigger['source'] then ": #{trigger['source']}"
        else ''
        end
      "#{trigger['type'] || '?'}#{suffix}"
    end
  end
end
