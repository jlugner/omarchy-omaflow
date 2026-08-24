# frozen_string_literal: true

module Omaflow
  module ScriptRegistry
    NAME = /\A[a-z0-9][a-z0-9-]{0,40}\z/
    ROOT = File.expand_path('../..', __dir__)
    BUILT_INS = {
      'lock-fingerprint-enable' => {
        'path' => File.join(ROOT, 'scripts', 'lock-fingerprint-enable'),
        'description' => 'Allow fingerprint authentication in a compatible Omarchy lock service',
        'probe' => %w[omarchy-shell lock fingerprintControlAvailable],
        'source' => 'built-in'
      },
      'lock-fingerprint-disable' => {
        'path' => File.join(ROOT, 'scripts', 'lock-fingerprint-disable'),
        'description' => 'Stop fingerprint authentication in a compatible Omarchy lock service',
        'probe' => %w[omarchy-shell lock fingerprintControlAvailable],
        'source' => 'built-in'
      }
    }.freeze

    module_function

    def entries = @entries ||= configured.merge(BUILT_INS)
    def entry(name) = entries[name.to_s]
    def built_in?(name) = BUILT_INS.key?(name.to_s)
    def valid_name?(name) = name.is_a?(String) && name.match?(NAME)

    def reset!
      @entries = nil
      @probe_results = nil
    end

    def configured
      Store.read_json(Paths.scripts_file, {}).each_with_object({}) do |(name, value), result|
        next unless valid_name?(name) && value.is_a?(Hash)

        result[name] = {
          'path' => value['path'],
          'description' => value['description'],
          'source' => 'user'
        }
      end
    end

    def inventory
      entries.sort.filter_map do |name, value|
        next unless available(name)

        { 'name' => name, 'description' => description(value), 'source' => value['source'] }
      end
    end

    def resolve(name)
      value = entry(name)
      return nil unless value

      path = canonical_path(value['path'])
      return nil unless path && path == value['path']

      value.merge('path' => path)
    end

    def available(name)
      value = resolve(name)
      return nil unless value

      probe = value['probe']
      return value unless probe.is_a?(Array)
      return value if probe_available?(probe)

      nil
    end

    def canonical_path(path)
      resolved = File.realpath(path.to_s)
      stat = File.lstat(resolved)
      return nil unless resolved.start_with?('/') && stat.file? && File.executable?(resolved) && safe_stat?(stat)

      directory = File.dirname(resolved)
      loop do
        return nil unless safe_stat?(File.lstat(directory))
        break if directory == '/'

        directory = File.dirname(directory)
      end
      resolved
    rescue SystemCallError
      nil
    end

    def safe_stat?(stat)
      trusted_owner = stat.uid.zero? || stat.uid == Process.uid || stat.uid == File.lstat('/').uid
      trusted_owner && stat.mode.nobits?(0o022)
    end

    def probe_available?(probe)
      @probe_results ||= {}
      return @probe_results[probe] if @probe_results.key?(probe)

      output, ok = Sys.capture(*probe)
      @probe_results[probe] = ok && output.strip == 'true'
    end

    def description(value)
      text = value['description'].to_s.gsub(/[[:cntrl:]]/, ' ').strip.sub(/\A-+/, '')
      text.empty? ? File.basename(value['path'].to_s) : text.slice(0, 160)
    end
  end
end
