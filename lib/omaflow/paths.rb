# frozen_string_literal: true

require 'fileutils'

module Omaflow
  module Paths
    module_function

    def env_dir(name, *fallback)
      value = ENV.fetch(name, '')
      value.empty? ? File.join(Dir.home, *fallback) : value
    end

    def config_dir = File.join(env_dir('XDG_CONFIG_HOME', '.config'), 'omaflow')
    def state_dir = File.join(env_dir('XDG_STATE_HOME', '.local', 'state'), 'omaflow')
    def rules_dir = File.join(config_dir, 'rules')
    def config_file = File.join(config_dir, 'config.json')
    def webhooks_file = File.join(config_dir, 'webhooks.json')
    def scripts_file = File.join(config_dir, 'scripts.json')
    def index_file = File.join(state_dir, 'index.json')
    def log_file = File.join(state_dir, 'log.jsonl')
    def domains_file = File.join(state_dir, 'domains.json')
    def watched_dirs_file = File.join(state_dir, 'watched-dirs.json')
    def cooldowns_file = File.join(state_dir, 'cooldowns.json')
    def armed_file = File.join(state_dir, 'armed.json')
    def seen_ssids_file = File.join(state_dir, 'seen-ssids.json')
    def timetrack_file = File.join(state_dir, 'timetrack.json')
    def staging_file = File.join(state_dir, 'staging.json')
    def first_run_file = File.join(state_dir, 'first_run_done')
    def snapshots_dir = File.join(state_dir, 'snapshots')
    def inbox_dir = File.join(state_dir, 'inbox')
    def omarchy_default_agent_file = File.join(env_dir('XDG_CONFIG_HOME', '.config'), 'omarchy', 'defaults', 'agent')

    def ensure_dirs
      FileUtils.mkdir_p([rules_dir, state_dir, snapshots_dir, inbox_dir])
      [config_dir, rules_dir, state_dir, snapshots_dir, inbox_dir].each { File.chmod(0o700, it) }
      [webhooks_file, scripts_file, timetrack_file, staging_file, log_file, armed_file].each do |path|
        File.chmod(0o600, path) if File.exist?(path)
      end
    rescue SystemCallError
      nil
    end

    def rule_file(id)
      return nil unless id.to_s.match?(/\A[a-z0-9][a-z0-9-]{0,40}\z/)

      File.join(rules_dir, "#{id}.json")
    end
  end
end
