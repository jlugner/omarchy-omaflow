# frozen_string_literal: true

module Omaflow
  module Desktop
    module_function

    def application_dirs
      data_home = ENV.fetch('XDG_DATA_HOME') { File.join(Dir.home, '.local', 'share') }
      [File.join(data_home, 'applications'), '/usr/share/applications', '/usr/local/share/applications']
    end

    def resolve(app)
      application_dirs.each do |dir|
        next unless Dir.exist?(dir)

        entries = Dir.glob(File.join(dir, '*.desktop')).sort
        found = entries.find { desktop_name?(it, app) } ||
                entries.find { File.basename(it) == "#{app}.desktop" } ||
                entries.find { File.basename(it).downcase.include?(app.downcase) }
        return File.basename(found, '.desktop') if found
      end
      nil
    end

    def desktop_name?(path, app)
      File.foreach(path).any? { it.match?(/\AName=#{Regexp.escape(app)}\s*\z/i) }
    rescue StandardError
      false
    end

    def installed_app_names(limit: 150)
      application_dirs.flat_map do |dir|
        Dir.glob(File.join(dir, '*.desktop')).filter_map do |path|
          File.foreach(path).find { it.start_with?('Name=') }&.delete_prefix('Name=')&.strip
        rescue StandardError
          nil
        end
      end.uniq.sort.first(limit)
    end
  end
end
