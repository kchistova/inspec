require 'json'

module Inspec::Plugin::V2
  class Loader
    attr_reader :registry, :options

    def initialize(options = {})
      @options = options
      @registry = Inspec::Plugin::V2::Registry.instance
      determine_plugin_conf_file
      read_conf_file
      unpack_conf_file
      detect_bundled_plugins unless options[:omit_bundles]
    end

    def load_all
      registry.each do |plugin_name, plugin_details|
        begin
          require plugin_details.entry_point
          plugin_details.loaded = true
          annotate_status_after_loading(plugin_name)
        rescue LoadError => ex
          plugin_details.load_exception = ex
          Inspec::Log.error "Could not load plugin #{plugin_name} at #{ex.path}"
        end
      end
    end

    private

    def annotate_status_after_loading(plugin_name)
      status = registry[plugin_name]
      return if status.api_generation == 2 # Gen2 have self-annotating superclasses
      case status.installation_type
      when :bundle
        annotate_bundle_plugin_status_after_load(plugin_name)
      else
        # TODO: are there any other cases? can this whole thing be eliminated?
        raise "I only know how to annotate :bundle plugins when trying to laod plugin #{plugin_name}" unless status.installation_type == :bundle
      end
    end

    def annotate_bundle_plugin_status_after_load(plugin_name)
      # HACK: we're relying on the fact that all bundles are gen0 and cli type
      status = registry[plugin_name]
      status.api_generation = 0
      status.plugin_types = [ :cli ]
      v0_subcommand_name = plugin_name.to_s.gsub('inspec-', '')
      status.plugin_class = Inspec::Plugins::CLI.subcommands[v0_subcommand_name][:klass]
    end

    def detect_bundled_plugins
      bundle_dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'bundles'))
      globs = [
        File.join(bundle_dir, 'inspec-*.rb'),
        File.join(bundle_dir, 'train-*.rb'),
      ]
      Dir.glob(globs).each do |loader_file|
        name = File.basename(loader_file, '.rb').gsub(/^(inspec|train)-/, '')
        status = Inspec::Plugin::V2::Status.new
        status.name = name
        status.entry_point = loader_file
        status.installation_type = :bundle
        status.loaded = false
        registry[name] = status
      end
    end

    def determine_plugin_conf_file
      # TODO: this assumes we can't read the --config-dir CLI option yet
      @plugin_conf_file_path = ENV['INSPEC_CONFIG_DIR'] ? ENV['INSPEC_CONFIG_DIR'] : File.join(Dir.home, '.inspec')
      @plugin_conf_file_path = File.join(@plugin_conf_file_path, 'plugins.json')
    end

    def read_conf_file
      if File.exist?(@plugin_conf_file_path)
        @plugin_file_contents = JSON.parse(File.read(@plugin_conf_file_path))
      else
        @plugin_file_contents = {
          'plugins_config_version' => '1.0.0',
          'plugins' => [],
        }
      end
    rescue JSON::ParserError => e
      raise Inspec::Plugin::V2::ConfigError, "Failed to load plugins JSON configuration from #{@plugin_conf_file_path}:\n#{e}"
    end

    def unpack_conf_file
      validate_conf_file
      @plugin_file_contents['plugins'].each do |plugin_json|
        status = Inspec::Plugin::V2::Status.new
        status.name = plugin_json['name'].to_sym
        status.loaded = false
        status.installation_type = plugin_json['installation_type'].to_sym
        case status.installation_type
        when :gem
          status.entry_point = status.name
          status.version = plugin_json['version']
        when :path
          status.entry_point = plugin_json['installation_path']
        end

        registry[status.name] = status
      end
    end

    def validate_conf_file
      unless @plugin_file_contents['plugins_config_version'] == '1.0.0'
        raise Inspec::Plugin::V2::ConfigError, "Unsupported plugins.json file version #{@plugin_file_contents[:plugins_config_version]} at #{@plugin_conf_file_path} - currently support versions: 1.0.0"
      end

      # TODO: validate config
    end
  end
end
