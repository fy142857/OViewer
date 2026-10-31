require 'minitest/autorun'
require 'xcodeproj'
require 'tmpdir'
require_relative '../../ios/deployment_target_guard'

class DeploymentTargetGuardTest < Minitest::Test
  def test_versions
    %w[9.0 11.0 12.0 12.0.0].each { |value| OViewerDeploymentTarget.verify!(value, 'test') }
    ['12.1', '13.0', '$(inherited)', 'garbage'].each do |value|
      assert_raises(RuntimeError) { OViewerDeploymentTarget.verify!(value, 'test') }
    end
  end

  def test_inherited_and_conditional_build_settings
    project = Xcodeproj::Project.new('/tmp/oviewer-guard-test.xcodeproj')
    target = project.new_target(:framework, 'Example', :ios, '12.0')
    OViewerDeploymentTarget.verify_target!(target)
    target.build_configurations.first.build_settings['IPHONEOS_DEPLOYMENT_TARGET[sdk=iphoneos*]'] = '13.0'
    assert_raises(RuntimeError) { OViewerDeploymentTarget.verify_target!(target) }
    target.build_configurations.first.build_settings.delete('IPHONEOS_DEPLOYMENT_TARGET[sdk=iphoneos*]')
    target.build_configurations.each { |config| config.build_settings.delete('IPHONEOS_DEPLOYMENT_TARGET') }
    project.build_configurations.each { |config| config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0' }
    assert_raises(RuntimeError) { OViewerDeploymentTarget.verify_target!(target) }
  end

  def test_pod_requirement
    require 'cocoapods'
    spec = Pod::Specification.new do |s|
      s.name = 'Example'
      s.version = '1.0'
      s.ios.deployment_target = '13.0'
    end
    target = Struct.new(:specs).new([spec])
    assert_raises(RuntimeError) { OViewerDeploymentTarget.verify_specs!([target]) }
    spec.ios.deployment_target = '12.0'
    OViewerDeploymentTarget.verify_specs!([target])
    child = spec.subspec('Child') {}
    inherited_target = Struct.new(:specs).new([child])
    OViewerDeploymentTarget.verify_specs!([inherited_target])
    spec.ios.deployment_target = '13.0'
    assert_raises(RuntimeError) { OViewerDeploymentTarget.verify_specs!([inherited_target]) }
  end

  def test_conditional_xcconfig_requirement
    Dir.mktmpdir do |directory|
      project = Xcodeproj::Project.new(File.join(directory, 'Example.xcodeproj'))
      target = project.new_target(:framework, 'Example', :ios, '12.0')
      path = File.join(directory, 'Example.xcconfig')
      File.write(path, "IPHONEOS_DEPLOYMENT_TARGET[sdk=iphoneos*] = 13.0\n")
      target.build_configurations.first.base_configuration_reference = project.new_file(path)
      assert_raises(RuntimeError) { OViewerDeploymentTarget.verify_target!(target) }
    end
  end
end
