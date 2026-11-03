defmodule IMAPClient.EnvelopesTest do
  use ExUnit.Case, async: true

  import IMAPClient.Envelopes

  test "parses INTERNALDATE to Unix milliseconds, rolling field overflow over" do
    for {input, expected} <- [
          {"17-Jul-1996 02:44:25 -0700", 837_596_665_000},
          {" 7-Jul-1996 09:44:25 +0000", 836_732_665_000},
          {"03-Feb-2026 04:05:06 +0530", 1_770_071_706_000},
          {"31-Feb-2026 00:00:00 +0000", 1_772_496_000_000},
          {"00-Mar-2026 00:00:00 +0000", 1_772_236_800_000},
          {"01-Jan-2026 99:00:00 +0000", 1_767_582_000_000},
          {"01-Jan-0070 00:00:00 +0000", 0}
        ] do
      assert parse_internal_date(input) == expected, input
    end

    for input <- ["", "17-Foo-1996 02:44:25 -0700", "17-Jul-1996 02:44 -0700", "garbage"] do
      assert parse_internal_date(input) == nil, input
    end
  end
end
