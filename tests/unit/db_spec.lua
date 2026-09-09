-- tests/unit/db_spec.lua
-- Unit tests for gelbooru.tags.db — tag validation and indexing.

local db = require("gelbooru.tags.db")
local state = require("gelbooru.core.state")

describe("db.is_clean_tag", function()
  it("accepts a normal tag", function()
    assert.is_true(db.is_clean_tag("hoshino_ai", 5000, 4))
  end)

  it("rejects tags shorter than 2 characters", function()
    assert.is_false(db.is_clean_tag("a", 100, 0))
  end)

  it("rejects nil name", function()
    assert.is_false(db.is_clean_tag(nil, 100, 0))
  end)

  it("rejects count < 1 for non-meta tags", function()
    assert.is_false(db.is_clean_tag("some_tag", 0, 0))
  end)

  it("accepts meta tags (type 5) regardless of count", function()
    assert.is_true(db.is_clean_tag("sort:score", 0, 5))
  end)

  it("rejects tags starting with a separator character", function()
    assert.is_false(db.is_clean_tag("-leading_dash", 100, 0))
    assert.is_false(db.is_clean_tag("_leading_underscore", 100, 0))
  end)

  it("rejects tags containing commas or semicolons", function()
    assert.is_false(db.is_clean_tag("a,b", 100, 0))
    assert.is_false(db.is_clean_tag("a;b", 100, 0))
  end)

  it("rejects URL-like tags", function()
    assert.is_false(db.is_clean_tag("https://example.com", 100, 0))
  end)

  it("rejects tags with double separators", function()
    assert.is_false(db.is_clean_tag("a__b", 100, 0))
    assert.is_false(db.is_clean_tag("a--b", 100, 0))
  end)

  it("rejects very long tags without parens", function()
    local long = ("a"):rep(46)
    assert.is_false(db.is_clean_tag(long, 100, 0))
  end)

  it("accepts long tags that contain parentheses (disambiguation)", function()
    local long = ("a"):rep(46) .. "_(character)"
    assert.is_true(db.is_clean_tag(long, 100, 0))
  end)
end)

describe("db.add_tag_to_index", function()
  local target_list
  local bucket_map

  before_each(function()
    target_list = {}
    bucket_map = {}
    -- Reset tags_by_name so tests don't interfere with each other.
    state.State.tags_by_name = {}
  end)

  it("adds a valid tag to target_list", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.are.equal(1, #target_list)
  end)

  it("stamps n_lower on the tag object", function()
    local t = { n = "Hoshino_Ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.are.equal("hoshino_ai", target_list[1].n_lower)
  end)

  it("registers tag in tags_by_name", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.is_not_nil(state.State.tags_by_name["hoshino_ai"])
  end)

  it("buckets the tag by first letter", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.is_not_nil(bucket_map["h"])
    assert.are.equal(1, #bucket_map["h"])
  end)

  it("skips invalid tags silently", function()
    db.add_tag_to_index({ n = "a", c = 0, t = 0 }, target_list, bucket_map)
    assert.are.equal(0, #target_list)
  end)

  it("works with nil target_list (tags_by_name only)", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    assert.has_no.errors(function()
      db.add_tag_to_index(t, nil, nil)
    end)
    assert.is_not_nil(state.State.tags_by_name["hoshino_ai"])
  end)
end)
