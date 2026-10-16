-- tests/unit/query_spec.lua
-- Unit tests for the dedicated gelbooru.query package and submodules:
-- parse, pipeline, sort, and filter.

local query = require("gelbooru.query")
local query_parse = require("gelbooru.query.parse")
local query_pipeline = require("gelbooru.query.pipeline")
local query_sort = require("gelbooru.query.sort")
local query_filter = require("gelbooru.query.filter")
local config = require("gelbooru.core.config")

describe("gelbooru.query: Package Facade", function()
  it("exposes all submodules correctly", function()
    assert.are.equal(query_parse, query.parse)
    assert.are.equal(query_pipeline, query.pipeline)
    assert.are.equal(query_sort, query.sort)
    assert.are.equal(query_filter, query.filter)
  end)

  it("exposes all parsing, pipeline, sorting, and filtering functions on facade", function()
    -- Parsing
    assert.is_function(query.normalize_rating)
    assert.is_function(query.tokenize_query)
    assert.is_function(query.is_dir_token)
    assert.is_function(query.parse_limit_or_range)
    assert.is_function(query.parse_stage)
    assert.is_function(query.parse_sort_token)
    assert.is_function(query.parse_query)
    assert.is_function(query.parse_local_query)
    assert.is_function(query.parse_tags)

    -- Pipeline
    assert.is_function(query.split_by_pipeline_pipe)
    assert.is_function(query.parse_pipeline)
    assert.is_function(query.execute_pipeline)

    -- Sorting
    assert.is_function(query.sort_posts)
    assert.is_function(query.get_post_score)
    assert.is_function(query.get_post_mtime)

    -- Filtering
    assert.is_function(query.matches_post)
    assert.is_function(query.matches_query)
    assert.is_function(query.filter_posts)
  end)
end)

describe("gelbooru.query.parse: Tokenizer and Modifier Parser", function()
  describe("normalize_rating", function()
    it("normalizes short abbreviations and full rating names", function()
      assert.are.equal("general", query_parse.normalize_rating("g"))
      assert.are.equal("general", query_parse.normalize_rating("G"))
      assert.are.equal("general", query_parse.normalize_rating("general"))
      assert.are.equal("sensitive", query_parse.normalize_rating("s"))
      assert.are.equal("sensitive", query_parse.normalize_rating("sensitive"))
      assert.are.equal("questionable", query_parse.normalize_rating("q"))
      assert.are.equal("questionable", query_parse.normalize_rating("questionable"))
      assert.are.equal("explicit", query_parse.normalize_rating("e"))
      assert.are.equal("explicit", query_parse.normalize_rating("explicit"))
    end)

    it("returns nil for missing or question mark ratings", function()
      assert.is_nil(query_parse.normalize_rating(nil))
      assert.is_nil(query_parse.normalize_rating(""))
      assert.is_nil(query_parse.normalize_rating("?"))
    end)
  end)

  describe("normalize_modifier_spacing", function()
    it("strips whitespace following modifier colons", function()
      assert.are.equal("sort:score", query_parse.normalize_modifier_spacing("sort: score"))
      assert.are.equal("order:desc", query_parse.normalize_modifier_spacing("order: desc"))
      assert.are.equal("rating:general", query_parse.normalize_modifier_spacing("rating: general"))
      assert.are.equal("score:>=50", query_parse.normalize_modifier_spacing("score: >=50"))
      assert.are.equal("id:12345", query_parse.normalize_modifier_spacing("id: 12345"))
      assert.are.equal("limit:20", query_parse.normalize_modifier_spacing("limit: 20"))
      assert.are.equal("offset:10", query_parse.normalize_modifier_spacing("offset: 10"))
    end)

    it("handles leading ~ or - prefixes in modifiers", function()
      assert.are.equal("~rating:general", query_parse.normalize_modifier_spacing("~rating: general"))
      assert.are.equal("-rating:explicit", query_parse.normalize_modifier_spacing("-rating: explicit"))
      assert.are.equal("~sort:random", query_parse.normalize_modifier_spacing("~sort: random"))
    end)

    it("handles nil and non-string inputs safely", function()
      assert.is_nil(query_parse.normalize_modifier_spacing(nil))
      assert.are.equal(12345, query_parse.normalize_modifier_spacing(12345))
    end)
  end)

  describe("tokenize_query", function()
    it("splits unquoted whitespace tokens", function()
      local tokens = query_parse.tokenize_query("hatsune_miku 1girl vocaloid")
      assert.are.equal(3, #tokens)
      assert.are.equal("hatsune_miku", tokens[1].text)
      assert.are.equal("1girl", tokens[2].text)
      assert.are.equal("vocaloid", tokens[3].text)
    end)

    it("preserves double and single quotes", function()
      local tokens = query_parse.tokenize_query('tag1 "quoted tag" \'another tag\'')
      assert.are.equal(3, #tokens)
      assert.are.equal("tag1", tokens[1].text)
      assert.are.equal("quoted tag", tokens[2].text)
      assert.is_true(tokens[2].quoted)
      assert.are.equal("another tag", tokens[3].text)
      assert.is_true(tokens[3].quoted)
    end)

    it("extracts local: quoted directory paths correctly", function()
      local tokens = query_parse.tokenize_query('local:"/path with spaces/saved" tag1')
      assert.are.equal(2, #tokens)
      assert.is_true(tokens[1].is_local_dir)
      assert.are.equal("/path with spaces/saved", tokens[1].text)
      assert.are.equal("tag1", tokens[2].text)
    end)
  end)

  describe("parse_limit_or_range", function()
    it("parses open offset ranges (50.. or 50-)", function()
      local o, l, r = query_parse.parse_limit_or_range("50..")
      assert.are.equal(50, o)
      assert.is_nil(l)
      assert.is_true(r)

      local o2, l2, r2 = query_parse.parse_limit_or_range("50-")
      assert.are.equal(50, o2)
      assert.is_nil(l2)
      assert.is_true(r2)
    end)

    it("parses open limit ranges (..100)", function()
      local o, l, r = query_parse.parse_limit_or_range("..100")
      assert.are.equal(1, o)
      assert.are.equal(100, l)
      assert.is_true(r)
    end)

    it("parses bounded ranges (10..50 or 10-50)", function()
      local o, l = query_parse.parse_limit_or_range("10..50")
      assert.are.equal(10, o)
      assert.are.equal(50, l)

      local o2, l2 = query_parse.parse_limit_or_range("10-50")
      assert.are.equal(10, o2)
      assert.are.equal(50, l2)
    end)

    it("normalizes inverted range bounds (50..10)", function()
      local o, l = query_parse.parse_limit_or_range("50..10")
      assert.are.equal(10, o)
      assert.are.equal(50, l)
    end)

    it("parses exact numeric limit (25)", function()
      local o, l = query_parse.parse_limit_or_range("25")
      assert.is_nil(o)
      assert.are.equal(25, l)
    end)

    it("returns nil for invalid values", function()
      local o, l = query_parse.parse_limit_or_range("invalid")
      assert.is_nil(o)
      assert.is_nil(l)
    end)
  end)

  describe("parse_stage", function()
    it("parses random directives", function()
      local s1 = query_parse.parse_stage("random")
      assert.are.equal("random", s1.key)
      assert.are.equal("asc", s1.dir)

      local s2 = query_parse.parse_stage("order:random")
      assert.are.equal("random", s2.key)

      local s3 = query_parse.parse_stage("sort:random:10")
      assert.are.equal("random", s3.key)
      assert.are.equal(10, s3.limit)
    end)

    it("parses sort directives with direction and limits", function()
      local s = query_parse.parse_stage("sort:score:asc")
      assert.are.equal("score", s.key)
      assert.are.equal("asc", s.dir)

      local s2 = query_parse.parse_stage("sort:id:10..50")
      assert.are.equal("id", s2.key)
      assert.are.equal(10, s2.offset)
      assert.are.equal(50, s2.limit)
    end)

    it("parses limit and offset stages", function()
      local s_lim = query_parse.parse_stage("limit:20")
      assert.are.equal(20, s_lim.limit)

      local s_off = query_parse.parse_stage("offset:50")
      assert.are.equal(50, s_off.offset)
    end)
  end)

  describe("parse_tags", function()
    it("parses positive, negative, and rating tags", function()
      local f = query_parse.parse_tags("hatsune_miku -bad_tag rating:general -rating:explicit score:>=100")
      assert.are.same({ "hatsune_miku" }, f.positive_tags)
      assert.are.same({ "bad_tag" }, f.negative_tags)
      assert.are.equal(2, #f.ratings)
      assert.are.equal("eq", f.ratings[1].op)
      assert.are.equal("general", f.ratings[1].val)
      assert.are.equal("neq", f.ratings[2].op)
      assert.are.equal("explicit", f.ratings[2].val)
      assert.are.equal(1, #f.scores)
      assert.are.equal(">=", f.scores[1].op)
      assert.are.equal(100, f.scores[1].val)
    end)

    it("parses artist and character modifiers", function()
      local f = query_parse.parse_tags("artist:ryo -artist:unknown character:miku")
      assert.are.equal(2, #f.artists)
      assert.are.equal("eq", f.artists[1].op)
      assert.are.equal("ryo", f.artists[1].val)
      assert.are.equal("neq", f.artists[2].op)
      assert.are.equal("unknown", f.artists[2].val)
      assert.are.equal(1, #f.characters)
      assert.are.equal("eq", f.characters[1].op)
      assert.are.equal("miku", f.characters[1].val)
    end)

    it("parses numeric id modifiers", function()
      local f = query_parse.parse_tags("id:98765")
      assert.are.same({ "98765" }, f.ids)
    end)

    it("parses intra-token pipe OR and tilde OR syntax", function()
      local f = query_parse.parse_tags("tagA|tagB ~tagC")
      assert.are.same({ "taga", "tagb", "tagc" }, f.or_tags)
    end)
  end)

  describe("parse_query", function()
    it("defaults to config save_dir when query is empty or local:", function()
      local dir1, tags1, f1 = query_parse.parse_query("")
      assert.are.equal(config.options.save_dir, dir1)
      assert.are.equal("", tags1)

      local dir2, tags2, f2 = query_parse.parse_query("local:")
      assert.are.equal(config.options.save_dir, dir2)
      assert.are.equal("", tags2)
    end)

    it("parses local directory with tags and sort directives", function()
      local dir, tags, f = query_parse.parse_query("local:/tmp/my_folder miku sort:score:desc")
      assert.are.equal("/tmp/my_folder", dir)
      assert.are.equal("miku sort:score:desc", tags)
      assert.are.same({ "miku" }, f.positive_tags)
      assert.is_not_nil(f.sort)
      assert.are.equal("score", f.sort.key)
      assert.are.equal("desc", f.sort.dir)
    end)

    it("supports flexible placement where local: appears anywhere", function()
      local dir, tags, f = query_parse.parse_query("miku local: sort:score")
      assert.are.equal(config.options.save_dir, dir)
      assert.are.equal("miku sort:score", tags)
      assert.are.same({ "miku" }, f.positive_tags)
    end)
  end)
end)

describe("gelbooru.query.pipeline: Multi-Stage Piped Execution", function()
  describe("parse_pipeline", function()
    it("splits query by pipe delimiters and builds pipeline stages", function()
      local p = query_pipeline.parse_pipeline("hatsune_miku | sort:score:desc | limit:10..50")
      assert.are.equal("hatsune_miku", p.base_query)
      assert.are.equal(2, #p.stages)
      assert.are.equal("score", p.stages[1].key)
      assert.are.equal("desc", p.stages[1].dir)
      assert.are.equal(10, p.stages[2].offset)
      assert.are.equal(50, p.stages[2].limit)
    end)

    it("handles space-separated limit/offset without pipe as pipeline", function()
      local p = query_pipeline.parse_pipeline("vocaloid limit:15")
      assert.are.equal("vocaloid", p.base_query)
      assert.are.equal(1, #p.stages)
      assert.are.equal(15, p.stages[1].limit)
    end)

    it("handles empty stages, consecutive pipes, and trailing pipes cleanly", function()
      -- Empty middle stage
      local p1 = query_pipeline.parse_pipeline("miku | | sort:score")
      assert.are.equal("miku", p1.base_query)
      assert.are.equal(1, #p1.stages)
      assert.are.equal("score", p1.stages[1].key)

      -- Consecutive pipes
      local p2 = query_pipeline.parse_pipeline("miku ||| sort:id:asc")
      assert.are.equal("miku", p2.base_query)
      assert.are.equal(1, #p2.stages)
      assert.are.equal("id", p2.stages[1].key)
      assert.are.equal("asc", p2.stages[1].dir)

      -- Trailing pipes
      local p3 = query_pipeline.parse_pipeline("miku |")
      assert.are.equal("miku", p3.base_query)
      assert.are.equal(0, #p3.stages)

      local p4 = query_pipeline.parse_pipeline("miku | | ")
      assert.are.equal("miku", p4.base_query)
      assert.are.equal(0, #p4.stages)

      -- Bare pipes
      local p5 = query_pipeline.parse_pipeline("|||")
      assert.are.equal("", p5.base_query)
      assert.are.equal(0, #p5.stages)

      -- Leading pipe
      local p6 = query_pipeline.parse_pipeline("| sort:random")
      assert.are.equal("", p6.base_query)
      assert.are.equal(1, #p6.stages)
      assert.are.equal("random", p6.stages[1].key)
    end)

    it("normalizes inverted range bounds across stages (sort:id:100..20)", function()
      local p = query_pipeline.parse_pipeline("sort:id:100..20")
      assert.are.equal(1, #p.stages)
      assert.are.equal(20, p.stages[1].offset)
      assert.are.equal(100, p.stages[1].limit)
    end)

    it("handles malformed or non-numeric range bounds gracefully without throwing", function()
      local ok1, p1 = pcall(query_pipeline.parse_pipeline, "sort:id:abc..def")
      assert.is_true(ok1)
      assert.is_not_nil(p1)

      local ok2, p2 = pcall(query_pipeline.parse_pipeline, "sort:id:..")
      assert.is_true(ok2)
      assert.is_not_nil(p2)
    end)
  end)


  describe("execute_pipeline", function()
    local sample_posts

    before_each(function()
      sample_posts = {
        { id = 1, score = 10, file_url = "/path/1.jpg" },
        { id = 2, score = 50, file_url = "/path/2.jpg" },
        { id = 3, score = 30, file_url = "/path/3.jpg" },
        { id = 4, score = 90, file_url = "/path/4.jpg" },
        { id = 5, score = 20, file_url = "/path/5.jpg" },
      }
    end)

    it("sorts posts by score descending and slices to limit", function()
      local stages = {
        { key = "score", dir = "desc" },
        { limit = 2 },
      }
      local res = query_pipeline.execute_pipeline(sample_posts, stages)
      assert.are.equal(2, #res)
      assert.are.equal(4, res[1].id) -- score 90
      assert.are.equal(2, res[2].id) -- score 50
    end)

    it("slices posts with offset and limit range (2..4)", function()
      local stages = {
        { key = "score", dir = "desc" },
        { offset = 2, limit = 4, is_range = true },
      }
      -- Sorted: id 4 (90), id 2 (50), id 3 (30), id 5 (20), id 1 (10)
      -- Range 2..4 should pick items 2, 3, 4 -> ids 2, 3, 5
      local res = query_pipeline.execute_pipeline(sample_posts, stages)
      assert.are.equal(3, #res)
      assert.are.equal(2, res[1].id)
      assert.are.equal(3, res[2].id)
      assert.are.equal(5, res[3].id)
    end)

    it("slices open-ended offset range (3..)", function()
      local stages = {
        { key = "score", dir = "desc" },
        { offset = 3, is_range = true },
      }
      -- Sorted: id 4 (90), id 2 (50), id 3 (30), id 5 (20), id 1 (10)
      -- Range 3.. picks items 3 to end -> ids 3, 5, 1
      local res = query_pipeline.execute_pipeline(sample_posts, stages)
      assert.are.equal(3, #res)
      assert.are.equal(3, res[1].id)
      assert.are.equal(5, res[2].id)
      assert.are.equal(1, res[3].id)
    end)

    it("handles empty stages gracefully and returns posts unchanged", function()
      local res = query_pipeline.execute_pipeline(sample_posts, {})
      assert.are.equal(#sample_posts, #res)
      assert.are.equal(sample_posts[1].id, res[1].id)
    end)
  end)
end)

describe("gelbooru.query.sort: Post Sorting", function()
  it("sorts by post id ascending and descending", function()
    local posts = {
      { id = 50 },
      { id = 10 },
      { id = 90 },
      { id = 30 },
    }

    query_sort.sort_posts(posts, { key = "id", dir = "asc" })
    assert.are.equal(10, posts[1].id)
    assert.are.equal(30, posts[2].id)
    assert.are.equal(50, posts[3].id)
    assert.are.equal(90, posts[4].id)

    query_sort.sort_posts(posts, { key = "id", dir = "desc" })
    assert.are.equal(90, posts[1].id)
    assert.are.equal(50, posts[2].id)
    assert.are.equal(30, posts[3].id)
    assert.are.equal(10, posts[4].id)
  end)

  it("sorts by post score descending and handles missing score", function()
    local posts = {
      { id = 1, score = 15 },
      { id = 2, score = 0 },
      { id = 3, score = 45 },
      { id = 4 }, -- nil score
    }

    query_sort.sort_posts(posts, { key = "score", dir = "desc" })
    assert.are.equal(3, posts[1].id) -- 45
    assert.are.equal(1, posts[2].id) -- 15
    assert.are.equal(0, posts[3].score)
  end)
end)

describe("gelbooru.query.filter: Post Filtering & Matching", function()
  local posts

  before_each(function()
    posts = {
      { id = 101, tags = "hatsune_miku 1girl vocaloid solo", rating = "general", score = 80, file_url = "/save/101.jpg" },
      { id = 102, tags = "kagamine_rin 1girl vocaloid", rating = "general", score = 40, file_url = "/save/102.jpg" },
      { id = 103, tags = "hatsune_miku 1girl swimsuit", rating = "questionable", score = 120, file_url = "/save/103.jpg" },
      { id = 104, tags = "megurine_luka 1girl explicit_tag", rating = "explicit", score = 5, file_url = "/save/104.jpg" },
    }
  end)

  it("filters posts by positive and negative tags", function()
    local res = query_filter.filter_posts(posts, "vocaloid -solo")
    assert.are.equal(1, #res)
    assert.are.equal(102, res[1].id)
  end)

  it("filters posts by rating and score criteria", function()
    local res = query_filter.filter_posts(posts, "rating:general score:>=50")
    assert.are.equal(1, #res)
    assert.are.equal(101, res[1].id)
  end)

  it("filters posts by OR condition (~tag1 ~tag2)", function()
    local res = query_filter.filter_posts(posts, "~kagamine_rin ~megurine_luka")
    assert.are.equal(2, #res)
    assert.are.equal(102, res[1].id)
    assert.are.equal(104, res[2].id)
  end)

  it("matches post against filename stem tokens as fallback", function()
    local untagged = {
      { id = 201, tags = "", rating = "general", score = 0, file_url = "/save/[Artist]_Hatsune_Miku_Smile.jpg" },
    }
    local res = query_filter.filter_posts(untagged, "miku")
    assert.are.equal(1, #res)
    assert.are.equal(201, res[1].id)
  end)

  it("chains filtering with sort and pipeline directives", function()
    local res = query_filter.filter_posts(posts, "vocaloid | sort:score:desc | limit:1")
    assert.are.equal(1, #res)
    assert.are.equal(101, res[1].id) -- vocaloid with score 80 > 40
  end)
end)
