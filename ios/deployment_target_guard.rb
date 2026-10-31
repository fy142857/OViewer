# Do not hide a dependency's newer minimum by overwriting it with 12.0.
module OViewerDeploymentTarget
  MAXIMUM = Gem::Version.new('12.0')

  def self.verify!(value, source)
    return if value.nil? || value.to_s.empty?

    text = value.to_s
    unless text.match?(/\A\d+(\.\d+){0,2}\z/)
      raise "Unresolved iOS deployment target #{text.inspect}: #{source}"
    end
    if Gem::Version.new(text) > MAXIMUM
      raise "#{source} requires iOS #{text}, above the application's iOS 12.0 minimum"
    end
  end

  def self.verify_specs!(pod_targets)
    pod_targets.each do |target|
      target.specs.each do |spec|
        verify!(spec.consumer(:ios).deployment_target, "Pod #{spec.name}")
      end
    end
  end

  def self.verify_target!(target)
    target.resolved_build_setting('IPHONEOS_DEPLOYMENT_TARGET', true).each do |config, value|
      verify!(value, "#{target.name} / #{config}")
    end
    # Also reject conditional overrides which the ordinary resolved setting omits.
    target.build_configurations.each do |config|
      project_config = config.project.build_configuration_list.build_configurations
        .find { |candidate| candidate.name == config.name }
      [config, project_config].compact.each do |configuration|
        settings_sources = [configuration.build_settings]
        reference = configuration.base_configuration_reference
        settings_sources << Xcodeproj::Config.new(reference.real_path).to_hash if reference && reference.real_path.exist?
        settings_sources.each do |settings|
          settings.each do |key, value|
            verify!(value, "#{target.name} / #{config.name} / #{key}") if key.start_with?('IPHONEOS_DEPLOYMENT_TARGET[')
          end
        end
      end
    end
  end
end
