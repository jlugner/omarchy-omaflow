# frozen_string_literal: true

require 'fileutils'

module Omaflow
  module Paths
    module_function

    def config_dir = File.join(ENV.fetch('XDG_CONFIG_HOME') { File.join(Dir.home, '.config') }, 'omaflow')
    def state_dir = File.join(ENV.fetch('XDG_STATE_HOME') { File.join(Dir.home, '.local', 'state') }, 'omaflow')
    def rules_dir = File.join(config_dir, 'rules')
    def config_file = File.join(config_dir, 'config.json')
    def webhooks_file = File.join(config_dir, 'webhooks.json')
    def index_file = File.join(state_dir, 'index.json')
    def log_file = File.join(state_dir, 'log.jsonl')
    def domains_file = File.join(state_dir, 'domains.json')
    def cooldowns_file = File.join(state_dir, 'cooldowns.json')
    def seen_ssids_file = File.join(state_dir, 'seen-ssids.json')
    def staging_file = File.join(state_dir, 'staging.json')
    def snapshots_dir = File.join(state_dir, 'snapshots')
    def omarchy_default_agent_file = File.join(ENV.fetch('XDG_CONFIG_HOME') { File.join(Dir.home, '.config') }, 'omarchy', 'defaults', 'agent')

    def ensure_dirs = FileUtils.mkdir_p([rules_dir, state_dir, snapshots_dir])

    def rule_file(id)
      return nil unless id.to_s.match?(/\A[a-z0-9][a-z0-9-]{0,40}\z/)

      File.join(rules_dir, "#{id}.json")
    end
  end
end
