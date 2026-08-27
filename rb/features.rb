# Univec SDK feature factory

require_relative 'feature/base_feature'
require_relative 'feature/test_feature'


module UnivecFeatures
  def self.make_feature(name)
    case name
    when "base"
      UnivecBaseFeature.new
    when "test"
      UnivecTestFeature.new
    else
      UnivecBaseFeature.new
    end
  end
end
