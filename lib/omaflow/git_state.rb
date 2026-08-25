# frozen_string_literal: true

module Omaflow
  module GitState
    module_function

    GITDIR_BYTES_LIMIT = 4096
    HEAD_BYTES_LIMIT = 4096

    def git_dir(repo)
      expanded_repo = File.expand_path(repo)
      dot_git = File.join(expanded_repo, '.git')
      return dot_git if File.directory?(dot_git)
      return nil unless File.file?(dot_git)

      match = Store.safe_read(dot_git, max_bytes: GITDIR_BYTES_LIMIT).match(/\A\s*gitdir:\s*(.+)\s*\z/m)
      return nil unless match

      resolved = File.expand_path(match[1].strip, expanded_repo)
      resolved if File.directory?(resolved)
    rescue StandardError
      nil
    end

    def current_branch(repo)
      directory = git_dir(repo)
      return nil unless directory

      head = Store.safe_read(File.join(directory, 'HEAD'), max_bytes: HEAD_BYTES_LIMIT)
      match = head.match(%r{\Aref: refs/heads/(.+)\s*\z}m)
      return clean_branch(match[1]) if match
      return 'detached' if head.match?(/\A[0-9a-f]{40}\s*\z/i)

      nil
    rescue StandardError
      nil
    end

    def clean_branch(value)
      branch = value.scrub.gsub(/[[:cntrl:]]/, '').strip[0, 120]
      branch unless branch.empty?
    end
  end
end
