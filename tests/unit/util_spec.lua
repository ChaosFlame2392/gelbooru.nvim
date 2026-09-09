-- tests/unit/util_spec.lua
-- Unit tests for gelbooru.core.util (pure functions only — no vim API needed).

local util = require("gelbooru.core.util")

describe("util.url_encode", function()
  it("encodes spaces as +", function()
    assert.are.equal("hello+world", util.url_encode("hello world"))
  end)

  it("encodes special characters", function()
    local enc = util.url_encode("a&b=c")
    assert.is_falsy(enc:find("&"))
    assert.is_falsy(enc:find("="))
  end)

  it("leaves alphanumerics untouched", function()
    assert.are.equal("abc123", util.url_encode("abc123"))
  end)

  it("encodes colons", function()
    -- sort:score is a common gelbooru tag modifier
    local enc = util.url_encode("sort:score")
    assert.are.equal("sort%3Ascore", enc)
  end)

  it("handles empty string", function()
    assert.are.equal("", util.url_encode(""))
  end)

  it("handles nil gracefully", function()
    assert.are.equal("", util.url_encode(nil))
  end)
end)

describe("util.normalize_str", function()
  it("strips non-word characters", function()
    assert.are.equal("helloworld", util.normalize_str("hello_world"))
  end)

  it("lowercases result", function()
    assert.are.equal("abc", util.normalize_str("ABC"))
  end)

  it("handles nil", function()
    assert.are.equal("", util.normalize_str(nil))
  end)
end)

describe("util.decode_html", function()
  it("decodes &gt; and &lt;", function()
    assert.are.equal("<b>", util.decode_html("&lt;b&gt;"))
  end)

  it("decodes &amp;", function()
    assert.are.equal("a&b", util.decode_html("a&amp;b"))
  end)

  it("decodes &quot;", function()
    assert.are.equal('"', util.decode_html("&quot;"))
  end)

  it("decodes &#039; and &#39;", function()
    assert.are.equal("'", util.decode_html("&#039;"))
    assert.are.equal("'", util.decode_html("&#39;"))
  end)

  it("returns empty string for nil", function()
    assert.are.equal("", util.decode_html(nil))
  end)

  it("leaves plain text unchanged", function()
    assert.are.equal("hello", util.decode_html("hello"))
  end)
end)

describe("util.fuzzy", function()
  it("matches subsequences", function()
    assert.is_true(util.fuzzy("zenless_zone_zero", "zzz"))
  end)

  it("is case-insensitive", function()
    assert.is_true(util.fuzzy("ZenlessZoneZero", "zzz"))
  end)

  it("empty query always matches", function()
    assert.is_true(util.fuzzy("anything", ""))
  end)

  it("returns false for non-matching subsequence", function()
    assert.is_false(util.fuzzy("abc", "xyz"))
  end)

  it("exact match succeeds", function()
    assert.is_true(util.fuzzy("tag", "tag"))
  end)
end)
