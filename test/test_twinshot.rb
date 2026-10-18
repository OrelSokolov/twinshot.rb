# frozen_string_literal: true

require "test_helper"

class TestTwinshot < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Twinshot::VERSION
  end

  def test_it_exposes_a_cli_entry_point
    assert File.executable?(File.expand_path("../exe/twinshot", __dir__))
  end
end
