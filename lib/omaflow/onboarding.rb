# frozen_string_literal: true

require 'fileutils'

module Omaflow
  module Onboarding
    PLUGIN_DIR = File.expand_path('../..', __dir__)
    MENU_BEGIN = '// omaflow:begin'
    MENU_END = '// omaflow:end'
    BINDINGS_BEGIN = '# omaflow:begin'
    BINDINGS_END = '# omaflow:end'
    MENU_BLOCK = <<~BLOCK.lines.map { "  #{it}" }.join.chomp.freeze
      // omaflow:begin
      "automations": {"icon": "󱐋", "label": "Automations", "action": "$HOME/.config/omarchy/plugins/jesperlugner.omaflow/bin/omaflow", "description": "Omaflow rules and authoring"},
      // omaflow:end
    BLOCK
    BINDINGS_BLOCK = <<~BLOCK.chomp.freeze
      # omaflow:begin
      bindd = SUPER SHIFT, U, Toggle Omaflow, exec, omarchy-shell shell toggle jesperlugner.omaflow
      # omaflow:end
    BLOCK

    class SetupError < StandardError; end

    module_function

    def setup(argv)
      yes = setup_options(argv)
      return 2 if yes.nil?

      unless yes || $stdin.tty?
        manual_steps
        return 1
      end

      failures = 0
      failures += 1 unless setup_step('1. CLI on PATH', "Create #{cli_link} pointing to this plugin's CLI.", yes:) { install_cli }
      failures += 1 unless setup_step('2. Menu entry', "Install Automations in #{menu_file}.", yes:) { install_menu }
      failures += 1 unless setup_step('3. Hotkey', 'Bind SUPER+SHIFT+U to toggle the Omaflow overlay.', yes:) { install_hotkey }
      failures += 1 unless doctor?
      failures.zero? ? 0 : 1
    end

    def first_run
      path = Paths.first_run_file
      return 0 if File.exist?(path)

      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { it.write('') }
      Sys.notify('Omaflow', 'Running. Open the menu: Automations. Or run: omaflow setup')
      0
    rescue Errno::EEXIST
      0
    rescue SystemCallError => e
      warn "Omaflow first-run: #{e.message}"
      1
    end

    def setup_options(argv)
      return false if argv.empty?
      return true if argv == ['--yes']

      warn 'Usage: omaflow setup [--yes]'
      nil
    end

    def setup_step(title, description, yes:)
      puts title
      puts "   #{description}"
      unless yes || consent?
        puts '   skipped'
        return true
      end
      yield
      true
    rescue SetupError, SystemCallError, IOError => e
      warn "   ✗ #{e.message}"
      false
    end

    def consent?
      print '   Continue? [Y/n] '
      answer = $stdin.gets
      answer && (answer.strip.empty? || %w[y yes].include?(answer.strip.downcase))
    end

    def install_cli
      source = File.join(PLUGIN_DIR, 'bin', 'omaflow')
      if File.symlink?(cli_link) && same_file?(cli_link, source)
        puts "   ✓ already linked: #{cli_link}"
        return
      end
      if File.exist?(cli_link) || File.symlink?(cli_link)
        raise SetupError, "#{cli_link} already exists and points elsewhere; refusing to overwrite"
      end

      FileUtils.mkdir_p(File.dirname(cli_link))
      File.symlink(source, cli_link)
      puts "   ✓ linked: #{cli_link}"
    end

    def install_menu
      if File.exist?(menu_file) || File.symlink?(menu_file)
        text = Store.safe_read(menu_file)
        updated = replace_or_insert_menu(text)
        write_atomic(menu_file, updated, mode: File.stat(menu_file).mode & 0o7777)
      else
        FileUtils.mkdir_p(File.dirname(menu_file))
        write_atomic(menu_file, "{\n#{MENU_BLOCK}\n}\n", mode: 0o644)
      end
      puts "   ✓ installed: #{menu_file}"
    end

    def replace_or_insert_menu(text)
      replaced = replace_marked(text, block: MENU_BLOCK, begin_marker: MENU_BEGIN, end_marker: MENU_END, path: menu_file)
      return replaced if replaced

      closing = text.rindex('}')
      raise SetupError, "#{menu_file} has no final closing brace; it needs manual attention" unless closing

      prefix = with_entry_comma(text[0...closing])
      separator = prefix.empty? || prefix.end_with?("\n") ? '' : "\n"
      "#{prefix}#{separator}#{MENU_BLOCK}\n#{text[closing..]}"
    end

    def with_entry_comma(prefix)
      lines = prefix.lines
      index = lines.rindex { it.strip != '' && !it.strip.start_with?('//') }
      return prefix unless index

      content = lines[index].rstrip
      return prefix if content.end_with?('{', ',')

      lines[index] = "#{content},#{lines[index][content.length..]}"
      lines.join
    end

    def install_hotkey
      output, ok = Sys.capture('hyprctl', 'binds', '-j', max_bytes: Store::MAX_JSON_BYTES)
      unless ok
        puts '   ! skipped: could not read current Hyprland bindings'
        return
      end
      bindings = JSON.parse(output)
      unless bindings.is_a?(Array)
        puts '   ! skipped: hyprctl returned invalid binding data'
        return
      end
      matches = bindings.grep(Hash).select { hotkey_binding?(it) }
      if matches.any? { JSON.generate(it).downcase.include?('omaflow') }
        puts '   ✓ SUPER+SHIFT+U is already bound to Omaflow'
        return
      end
      unless matches.empty?
        puts '   ! skipped: SUPER+SHIFT+U is already bound to something else'
        return
      end

      path = bindings_file
      unless path
        puts '   ! skipped: no Hyprland bindings.conf or hyprland.conf was found'
        return
      end
      text = Store.safe_read(path)
      updated = replace_marked(text, block: BINDINGS_BLOCK, begin_marker: BINDINGS_BEGIN, end_marker: BINDINGS_END, path:)
      separator = if text.empty?
                    ''
                  elsif text.end_with?("\n")
                    "\n"
                  else
                    "\n\n"
                  end
      updated ||= "#{text}#{separator}#{BINDINGS_BLOCK}\n"
      write_atomic(path, updated, mode: File.stat(path).mode & 0o7777)
      puts "   ✓ installed: #{path}"
    rescue JSON::ParserError
      puts '   ! skipped: hyprctl returned invalid binding data'
    end

    def hotkey_binding?(binding)
      return false unless binding['key'].to_s.casecmp('u').zero?

      mask = binding['modmask']
      return mask.to_i == 65 if mask.is_a?(Integer) || mask.to_s.match?(/\A\d+\z/)

      binding['mods'].to_s.upcase.split(/[+\s]+/).sort == %w[SHIFT SUPER]
    end

    def replace_marked(text, block:, begin_marker:, end_marker:, path:)
      begins = marker_positions(text, begin_marker)
      ends = marker_positions(text, end_marker)
      return nil if begins.empty? && ends.empty?

      unless begins.one? && ends.one? && begins.first < ends.first
        raise SetupError, "#{path} has an incomplete or duplicate Omaflow marker block; it needs manual attention"
      end

      start_at = line_start(text, begins.first)
      end_at = line_end(text, ends.first)
      "#{text[0...start_at]}#{block}#{text[end_at..]}"
    end

    def marker_positions(text, marker)
      positions = []
      offset = 0
      while (position = text.index(marker, offset))
        positions << position
        offset = position + marker.length
      end
      positions
    end

    def line_start(text, position) = text.rindex("\n", position - 1)&.next || 0
    def line_end(text, position) = text.index("\n", position) || text.length

    def write_atomic(path, content, mode:)
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{rand(1_000_000)}")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) { it.write(content) }
      File.chmod(mode, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def doctor?
      Paths.ensure_dirs
      failures = 0
      puts '4. Doctor'
      failures += doctor_command('ruby', required: true)
      failures += doctor_command('hyprctl', required: true)
      failures += doctor_command('nmcli', required: false)
      failures += doctor_rules
      failures += doctor_state
      failures += doctor_service
      failures += doctor_agent
      failures.zero?
    end

    def doctor_command(command, required:)
      path = Sys.which(command)
      if path
        puts "   ✓ #{command}: #{path}"
        0
      elsif required
        puts "   ✗ #{command}: not found"
        1
      else
        puts "   ! #{command}: not found"
        0
      end
    end

    def doctor_rules
      if File.directory?(Paths.rules_dir) && File.writable?(Paths.rules_dir)
        puts '   ✓ rules directory: writable'
        0
      else
        puts "   ✗ rules directory: not writable (#{Paths.rules_dir})"
        1
      end
    end

    def doctor_state
      mode = File.stat(Paths.state_dir).mode & 0o777
      if mode == 0o700
        puts '   ✓ state directory: permissions 0700'
        0
      else
        puts "   ✗ state directory: permissions #{format('%04o', mode)}, expected 0700"
        1
      end
    rescue SystemCallError
      puts "   ✗ state directory: unavailable (#{Paths.state_dir})"
      1
    end

    def doctor_service
      output, ok = Sys.capture('omarchy-shell', 'omaflow', 'ping')
      if ok && output.strip == 'ok'
        puts '   ✓ Omaflow service: reachable'
      else
        puts '   ! Omaflow service: not reachable; run omarchy-restart-shell once'
      end
      0
    end

    def doctor_agent
      backend = Agent.resolve
      if backend
        puts "   ✓ agent CLI: #{backend} (#{Sys.which(backend)})"
      else
        puts '   ! agent CLI: none found (codex, claude, or grok)'
      end
      0
    end

    def same_file?(left, right)
      File.realpath(left) == File.realpath(right)
    rescue SystemCallError
      false
    end

    def cli_link = File.join(Dir.home, '.local', 'bin', 'omaflow')
    def menu_file = File.join(Dir.home, '.config', 'omarchy', 'extensions', 'omarchy-menu.jsonc')

    def bindings_file
      paths = [
        File.join(Dir.home, '.config', 'hypr', 'bindings.conf'),
        File.join(Dir.home, '.config', 'hypr', 'hyprland.conf')
      ]
      paths.find { File.exist?(it) || File.symlink?(it) }
    end

    def manual_steps
      puts <<~TEXT
        Omaflow setup needs an interactive terminal. Run `omaflow setup --yes`, or complete these steps manually:
        1. Link #{cli_link} to #{File.join(PLUGIN_DIR, 'bin', 'omaflow')}.
        2. Add the Omaflow Automations entry between #{MENU_BEGIN.inspect} and #{MENU_END.inspect} in #{menu_file}.
        3. Add this binding between #{BINDINGS_BEGIN.inspect} and #{BINDINGS_END.inspect} in your Hyprland bindings file:
           #{BINDINGS_BLOCK.lines[1].strip}
        4. Check ruby, hyprctl, nmcli, directory permissions, shell IPC, and an agent CLI.
      TEXT
    end
  end
end
