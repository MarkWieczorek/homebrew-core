# typed: true
# frozen_string_literal: true

require "utils/link"
require "settings"
require "erb"

module Homebrew
  # Helper functions for generating shell completions.
  #
  # @api private
  module Completions
    extend T::Sig

    module_function

    COMPLETIONS_DIR = (HOMEBREW_REPOSITORY/"completions").freeze
    TEMPLATE_DIR = (HOMEBREW_LIBRARY_PATH/"completions").freeze

    SHELLS = %w[bash fish zsh].freeze
    COMPLETIONS_EXCLUSION_LIST = %w[
      instal
      uninstal
      update-report
    ].freeze

    BASH_NAMED_ARGS_COMPLETION_FUNCTION_MAPPING = {
      formula:           "__brew_complete_formulae",
      installed_formula: "__brew_complete_installed_formulae",
      outdated_formula:  "__brew_complete_outdated_formulae",
      cask:              "__brew_complete_casks",
      installed_cask:    "__brew_complete_installed_casks",
      outdated_cask:     "__brew_complete_outdated_casks",
      tap:               "__brew_complete_tapped",
      installed_tap:     "__brew_complete_tapped",
      command:           "__brew_complete_commands",
      diagnostic_check:  '__brewcomp "$(brew doctor --list-checks)"',
      file:              "__brew_complete_files",
    }.freeze

    ZSH_NAMED_ARGS_COMPLETION_FUNCTION_MAPPING = {
      formula:           "__brew_formulae",
      installed_formula: "__brew_installed_formulae",
      outdated_formula:  "__brew_outdated_formulae",
      cask:              "__brew_casks",
      installed_cask:    "__brew_installed_casks",
      outdated_cask:     "__brew_outdated_casks",
      tap:               "__brew_any_tap",
      installed_tap:     "__brew_installed_taps",
      command:           "__brew_commands",
      diagnostic_check:  "__brew_diagnostic_checks",
      file:              "__brew_formulae_or_ruby_files",
    }.freeze

    sig { void }
    def link!
      Settings.write :linkcompletions, true
      Tap.each do |tap|
        Utils::Link.link_completions tap.path, "brew completions link"
      end
    end

    sig { void }
    def unlink!
      Settings.write :linkcompletions, false
      Tap.each do |tap|
        next if tap.official?

        Utils::Link.unlink_completions tap.path
      end
    end

    sig { returns(T::Boolean) }
    def link_completions?
      Settings.read(:linkcompletions) == "true"
    end

    sig { returns(T::Boolean) }
    def completions_to_link?
      Tap.each do |tap|
        next if tap.official?

        SHELLS.each do |shell|
          return true if (tap.path/"completions/#{shell}").exist?
        end
      end

      false
    end

    sig { void }
    def show_completions_message_if_needed
      return if Settings.read(:completionsmessageshown) == "true"
      return unless completions_to_link?

      ohai "Homebrew completions for external commands are unlinked by default!"
      puts <<~EOS
        To opt-in to automatically linking external tap shell competion files, run:
          brew completions link
        Then, follow the directions at #{Formatter.url("https://docs.brew.sh/Shell-Completion")}
      EOS

      Settings.write :completionsmessageshown, true
    end

    sig { void }
    def update_shell_completions!
      commands = Commands.commands(external: false, aliases: true).sort

      puts "Writing completions to #{COMPLETIONS_DIR}"

      (COMPLETIONS_DIR/"bash/brew").atomic_write generate_bash_completion_file(commands)
      (COMPLETIONS_DIR/"zsh/_brew").atomic_write generate_zsh_completion_file(commands)
    end

    sig { params(command: String).returns(T::Boolean) }
    def command_gets_completions?(command)
      return false if command.start_with? "cask " # TODO: (2.8) remove when `brew cask` commands are removed

      command_options(command).any?
    end

    sig { params(description: String).returns(String) }
    def format_description(description)
      description.gsub("'", "'\\\\''").gsub(/[<>]/, "").tr("\n", " ").chomp(".")
    end

    sig { params(command: String).returns(T::Hash[String, String]) }
    def command_options(command)
      options = {}
      Commands.command_options(command)&.each do |option|
        next if option.blank?

        name = option.first
        desc = option.second
        if name.start_with? "--[no-]"
          options[name.remove("[no-]")] = desc
          options[name.sub("[no-]", "no-")] = desc
        else
          options[name] = desc
        end
      end
      options
    end

    sig { params(command: String).returns(T.nilable(String)) }
    def generate_bash_subcommand_completion(command)
      return unless command_gets_completions? command

      named_completion_string = ""
      if types = Commands.named_args_type(command)
        named_args_strings, named_args_types = types.partition { |type| type.is_a? String }

        named_args_types.each do |type|
          next unless BASH_NAMED_ARGS_COMPLETION_FUNCTION_MAPPING.key? type

          named_completion_string += "\n  #{BASH_NAMED_ARGS_COMPLETION_FUNCTION_MAPPING[type]}"
        end

        named_completion_string += "\n  __brewcomp \"#{named_args_strings.join(" ")}\"" if named_args_strings.any?
      end

      <<~COMPLETION
        _brew_#{Commands.method_name command}() {
          local cur="${COMP_WORDS[COMP_CWORD]}"
          case "$cur" in
            -*)
              __brewcomp "
              #{command_options(command).keys.sort.join("\n      ")}
              "
              return
              ;;
          esac#{named_completion_string}
        }
      COMPLETION
    end

    sig { params(commands: T::Array[String]).returns(String) }
    def generate_bash_completion_file(commands)
      variables = OpenStruct.new

      variables[:completion_functions] = commands.map do |command|
        generate_bash_subcommand_completion command
      end.compact

      variables[:function_mappings] = commands.map do |command|
        next unless command_gets_completions? command

        "#{command}) _brew_#{Commands.method_name command} ;;"
      end.compact

      ERB.new((TEMPLATE_DIR/"bash.erb").read, trim_mode: ">").result(variables.instance_eval { binding })
    end

    sig { params(command: String).returns(T.nilable(String)) }
    def generate_zsh_subcommand_completion(command)
      return unless command_gets_completions? command

      options = command_options(command).sort.map do |opt, desc|
        next opt if desc.blank?

        "#{opt}[#{format_description desc}]"
      end
      if types = Commands.named_args_type(command)
        named_args_strings, named_args_types = types.partition { |type| type.is_a? String }

        named_args_types.each do |type|
          next unless ZSH_NAMED_ARGS_COMPLETION_FUNCTION_MAPPING.key? type

          options << "::#{type}:#{ZSH_NAMED_ARGS_COMPLETION_FUNCTION_MAPPING[type]}"
        end

        options << "::subcommand:(#{named_args_strings.join(" ")})" if named_args_strings.any?
      end

      <<~COMPLETION
        # brew #{command}
        _brew_#{Commands.method_name command}() {
          _arguments \\
            #{options.map! { |opt| "'#{opt}'" }.join(" \\\n    ")}
        }
      COMPLETION
    end

    sig { params(commands: T::Array[String]).returns(String) }
    def generate_zsh_completion_file(commands)
      variables = OpenStruct.new

      variables[:aliases] = Commands::HOMEBREW_INTERNAL_COMMAND_ALIASES.map do |alias_command, command|
        alias_command = "'#{alias_command}'" if alias_command.start_with? "-"
        command = "'#{command}'" if command.start_with? "-"
        "#{alias_command} #{command}"
      end.compact

      variables[:builtin_command_descriptions] = commands.map do |command|
        next if Commands::HOMEBREW_INTERNAL_COMMAND_ALIASES.key? command

        description = Commands.command_description(command, short: true)
        next if description.blank?

        description = format_description description
        "'#{command}:#{description}'"
      end.compact

      variables[:completion_functions] = commands.map do |command|
        generate_zsh_subcommand_completion command
      end.compact

      ERB.new((TEMPLATE_DIR/"zsh.erb").read, trim_mode: ">").result(variables.instance_eval { binding })
    end
  end
end
