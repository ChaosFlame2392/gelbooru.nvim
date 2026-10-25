-- tests/unit/query_engine_spec.lua
-- Unit tests for gelbooru.query.engine (prepare & normalize_remote seams).

local config = require("gelbooru.core.config")
local util = require("gelbooru.core.util")

describe("gelbooru.query.engine", function()
  local engine

  before_each(function()
    config.setup({
      save_dir = "/tmp/gelbooru_saved",
    })
    engine = require("gelbooru.query.engine")
  end)

  describe("engine.prepare - empty and nil queries", function()
    it("returns a default QueryPlan when query_str is nil", function()
      local plan = engine.prepare(nil)
      assert.is_table(plan)
      assert.are.equal("", plan.raw)
      assert.is_false(plan.is_local)
      assert.are.equal(config.options.save_dir, plan.dir)
      assert.are.equal(config.options.save_dir, plan.target_dir)
      assert.are.equal("", plan.tag_str)
      assert.are.equal("", plan.base_query)
      assert.is_false(plan.is_random)
      assert.is_false(plan.is_pipeline)
      assert.is_false(plan.has_range)
      assert.is_false(plan.has_filter)
      assert.are.equal("", plan.remote_tags)
      assert.are.same({ "" }, plan.remote_branches)
      assert.are.same({}, plan.stages)
      assert.is_nil(plan.sort)
      assert.is_table(plan.filters)
      assert.are.same({}, plan.filters.positive_tags)
      assert.are.same({}, plan.filters.negative_tags)
      assert.are.same({}, plan.filters.or_tags)
      assert.are.same({}, plan.filters.ratings)
      assert.are.same({}, plan.filters.scores)
      assert.are.same({}, plan.filters.artists)
      assert.are.same({}, plan.filters.characters)
      assert.are.same({}, plan.filters.ids)
    end)

    it("returns a default QueryPlan when query_str is empty or whitespace", function()
      local plan = engine.prepare("   ")
      assert.is_table(plan)
      assert.are.equal("   ", plan.raw)
      assert.is_false(plan.is_local)
      assert.are.equal(config.options.save_dir, plan.dir)
      assert.are.equal("", plan.tag_str)
      assert.are.equal("", plan.base_query)
      assert.is_false(plan.is_random)
      assert.is_false(plan.is_pipeline)
      assert.is_false(plan.has_range)
      assert.is_false(plan.has_filter)
      assert.are.equal("", plan.remote_tags)
      assert.are.same({ "" }, plan.remote_branches)
      assert.are.same({}, plan.stages)
      assert.is_nil(plan.sort)
    end)
  end)

  describe("engine.prepare - filter criteria extraction & modifier normalization", function()
    it("extracts positive tags, negative tags, artists, characters, ids, ratings, and scores", function()
      local q = "hatsune_miku rating:general score:>=50 -video artist:some_artist character:some_char id:12345"
      local plan = engine.prepare(q)
      assert.is_false(plan.is_local)
      assert.is_false(plan.is_pipeline)
      assert.are.equal(q, plan.base_query)

      local f = plan.filters
      assert.are.same({ "hatsune_miku" }, f.positive_tags)
      assert.are.same({ "video" }, f.negative_tags)
      assert.are.same({ { op = "eq", val = "some_artist" } }, f.artists)
      assert.are.same({ { op = "eq", val = "some_char" } }, f.characters)
      assert.are.same({ "12345" }, f.ids)
      assert.are.same({ { op = "eq", val = "general" } }, f.ratings)
      assert.are.same({ { op = ">=", val = 50 } }, f.scores)
    end)

    it("normalizes modifier spacing e.g. sort: score:50 rating: general -rating: explicit", function()
      local q = "sort: score:50 rating: general -rating: explicit score: >=100 id: 999"
      local plan = engine.prepare(q)
      local f = plan.filters
      assert.are.same({ { op = "eq", val = "general" }, { op = "neq", val = "explicit" } }, f.ratings)
      assert.are.same({ { op = ">=", val = 100 } }, f.scores)
      assert.are.same({ "999" }, f.ids)
    end)

    it("handles rating aliases and comma/pipe multi-ratings in criteria", function()
      local q = "rating:q,e -rating:g"
      local plan = engine.prepare(q)
      local f = plan.filters
      assert.are.same({
        { op = "eq", val = "questionable" },
        { op = "eq", val = "explicit" },
        { op = "neq", val = "general" },
      }, f.ratings)
    end)

    it("handles intra-tag pipe disjunction and tilde OR tags in criteria", function()
      local q = "foot_focus|soles ~miku"
      local plan = engine.prepare(q)
      local f = plan.filters
      assert.are.same({ "foot_focus", "soles", "miku" }, f.or_tags)
    end)
  end)

  describe("engine.prepare - pipeline stages & range parsing", function()
    it("parses piped stages with sort, limit, and random", function()
      local q = "tag1 tag2 | sort:id:1000..1200 | sort:score:50 | sort:random"
      local plan = engine.prepare(q)
      assert.is_true(plan.is_pipeline)
      assert.is_true(plan.is_random)
      assert.is_true(plan.has_range)
      assert.are.equal("tag1 tag2", plan.base_query)
      assert.are.same({ "tag1", "tag2" }, plan.filters.positive_tags)
      assert.are.equal(3, #plan.stages)

      assert.are.equal("id", plan.stages[1].key)
      assert.are.equal("desc", plan.stages[1].dir)
      assert.are.equal(1000, plan.stages[1].offset)
      assert.are.equal(1200, plan.stages[1].limit)
      assert.is_true(plan.stages[1].is_range)

      assert.are.equal("score", plan.stages[2].key)
      assert.are.equal("desc", plan.stages[2].dir)
      assert.are.equal(50, plan.stages[2].limit)

      assert.are.equal("random", plan.stages[3].key)
      assert.are.equal("asc", plan.stages[3].dir)

      assert.is_table(plan.sort)
      assert.are.equal("id", plan.sort.key)
      assert.are.equal("desc", plan.sort.dir)
    end)

    it("parses bare range after pipe (e.g. miku | 1..30)", function()
      local plan = engine.prepare("miku | 1..30")
      assert.is_true(plan.is_pipeline)
      assert.is_true(plan.has_range)
      assert.are.equal("miku", plan.base_query)
      assert.are.equal(1, #plan.stages)
      assert.are.equal("id", plan.stages[1].key)
      assert.are.equal(1, plan.stages[1].offset)
      assert.are.equal(30, plan.stages[1].limit)
      assert.is_true(plan.stages[1].is_range)
    end)

    it("parses bare range at start of query (e.g. 500..600)", function()
      local plan = engine.prepare("500..600")
      assert.is_true(plan.is_pipeline)
      assert.is_true(plan.has_range)
      assert.are.equal("", plan.base_query)
      assert.are.equal(1, #plan.stages)
      assert.are.equal("id", plan.stages[1].key)
      assert.are.equal(500, plan.stages[1].offset)
      assert.are.equal(600, plan.stages[1].limit)
      assert.is_true(plan.stages[1].is_range)
    end)

    it("parses open-ended ranges (sort:id:..200 and sort:id:50..)", function()
      local p1 = engine.prepare("sort:id:..200")
      assert.is_true(p1.is_pipeline)
      assert.is_true(p1.has_range)
      assert.are.equal(1, #p1.stages)
      assert.are.equal(1, p1.stages[1].offset)
      assert.are.equal(200, p1.stages[1].limit)
      assert.is_true(p1.stages[1].is_range)

      local p2 = engine.prepare("sort:id:50..")
      assert.is_true(p2.is_pipeline)
      assert.is_true(p2.has_range)
      assert.are.equal(1, #p2.stages)
      assert.are.equal(50, p2.stages[1].offset)
      assert.is_nil(p2.stages[1].limit)
      assert.is_true(p2.stages[1].is_range)
    end)

    it("auto-swaps inverted ranges (sort:id:asc:50..10)", function()
      local plan = engine.prepare("sort:id:asc:50..10")
      assert.is_true(plan.is_pipeline)
      assert.is_true(plan.has_range)
      assert.are.equal(1, #plan.stages)
      assert.are.equal(10, plan.stages[1].offset)
      assert.are.equal(50, plan.stages[1].limit)
      assert.is_true(plan.stages[1].is_range)
      assert.are.equal("asc", plan.stages[1].dir)
    end)

    it("handles pipeline edge cases: bare pipes, empty stages, whitespace", function()
      local p_bare = engine.prepare("|")
      assert.is_false(p_bare.is_pipeline)
      assert.are.equal("", p_bare.base_query)
      assert.are.same({}, p_bare.stages)

      local p_multi_bare = engine.prepare(" | | | ")
      assert.is_false(p_multi_bare.is_pipeline)
      assert.are.equal("", p_multi_bare.base_query)
      assert.are.same({}, p_multi_bare.stages)

      local p_empty_stages = engine.prepare("tag | | | | sort:score")
      assert.is_true(p_empty_stages.is_pipeline)
      assert.are.equal("tag", p_empty_stages.base_query)
      assert.are.equal(1, #p_empty_stages.stages)
      assert.are.equal("score", p_empty_stages.stages[1].key)

      local p_trailing = engine.prepare("tag | sort:score |")
      assert.is_true(p_trailing.is_pipeline)
      assert.are.equal("tag", p_trailing.base_query)
      assert.are.equal(1, #p_trailing.stages)
      assert.are.equal("score", p_trailing.stages[1].key)

      local p_bare_num_pipe = engine.prepare("tag | 500")
      assert.is_true(p_bare_num_pipe.is_pipeline)
      assert.are.equal("tag", p_bare_num_pipe.base_query)
      assert.are.equal(1, #p_bare_num_pipe.stages)
      assert.are.equal(500, p_bare_num_pipe.stages[1].limit)

      -- Bare number at root without pipe should be preserved as tag
      local p_root_num = engine.prepare("12345")
      assert.is_false(p_root_num.is_pipeline)
      assert.are.equal("12345", p_root_num.base_query)
      assert.are.same({}, p_root_num.stages)
    end)
  end)

  describe("engine.prepare - local queries and directory detection", function()
    it("handles default local: prefix without arguments", function()
      local plan = engine.prepare("local:")
      assert.is_true(plan.is_local)
      assert.are.equal(config.options.save_dir, plan.dir)
      assert.are.equal(config.options.save_dir, plan.target_dir)
      assert.are.equal("", plan.tag_str)
      assert.are.equal("", plan.base_query)
      assert.are.same({}, plan.stages)
    end)

    it("handles local: with tags using default save_dir", function()
      local plan = engine.prepare("local: tag1 tag2")
      assert.is_true(plan.is_local)
      assert.are.equal(config.options.save_dir, plan.dir)
      assert.are.equal("tag1 tag2", plan.tag_str)
      assert.are.equal("tag1 tag2", plan.base_query)
      assert.are.same({ "tag1", "tag2" }, plan.filters.positive_tags)
    end)

    it("handles custom directory attached to local: prefix", function()
      local plan = engine.prepare("local:/custom/art_dir miku")
      assert.is_true(plan.is_local)
      assert.are.equal("/custom/art_dir", plan.dir)
      assert.are.equal("miku", plan.tag_str)
      assert.are.equal("miku", plan.base_query)
      assert.are.same({ "miku" }, plan.filters.positive_tags)
    end)

    it("handles quoted directory paths with spaces", function()
      local plan = engine.prepare('local:"/custom/my saved art" luka')
      assert.is_true(plan.is_local)
      assert.are.equal("/custom/my saved art", plan.dir)
      assert.are.equal("luka", plan.tag_str)
      assert.are.equal("luka", plan.base_query)
      assert.are.same({ "luka" }, plan.filters.positive_tags)
    end)

    it("detects local: placed anywhere in the query string", function()
      local plan = engine.prepare("tag1 local: tag2")
      assert.is_true(plan.is_local)
      assert.are.equal(config.options.save_dir, plan.dir)
      assert.are.equal("tag1 tag2", plan.tag_str)
      assert.are.same({ "tag1", "tag2" }, plan.filters.positive_tags)
    end)

    it("falls back to save_dir when token after local: is not a valid directory", function()
      local plan = engine.prepare("local:not_a_dir_tag1 tag2")
      assert.is_true(plan.is_local)
      assert.are.equal(config.options.save_dir, plan.dir)
      assert.are.equal("not_a_dir_tag1 tag2", plan.tag_str)
      assert.are.same({ "not_a_dir_tag1", "tag2" }, plan.filters.positive_tags)
    end)

    it("detects bare directory path without local: prefix", function()
      local plan = engine.prepare("/custom/path tag1")
      assert.is_true(plan.is_local)
      assert.are.equal("/custom/path", plan.dir)
      assert.are.equal("tag1", plan.tag_str)
      assert.are.same({ "tag1" }, plan.filters.positive_tags)
    end)

    it("handles complex local query with modifiers, negative tags, and pipelines", function()
      local q = "local:~/Art/ -tag1 ~rating:general | sort:date"
      local plan = engine.prepare(q)
      assert.is_true(plan.is_local)
      assert.are.equal("~/Art/", plan.dir)
      assert.are.equal("-tag1 ~rating:general | sort:date", plan.tag_str)
      assert.are.equal("-tag1 ~rating:general", plan.base_query)
      assert.are.same({ "tag1" }, plan.filters.negative_tags)
      assert.are.same({ { op = "eq", val = "general" } }, plan.filters.ratings)
      assert.is_true(plan.is_pipeline)
      assert.are.equal(1, #plan.stages)
      assert.are.equal("date", plan.stages[1].key)
      assert.are.equal("desc", plan.stages[1].dir)
      assert.are.equal("", plan.remote_tags)
      assert.are.same({ "" }, plan.remote_branches)
    end)
  end)

  describe("engine.normalize_remote", function()
    it("handles nil and empty strings", function()
      assert.are.same({ "" }, engine.normalize_remote(nil))
      assert.are.same({ "" }, engine.normalize_remote(""))
      assert.are.same({ "" }, engine.normalize_remote("   "))
    end)

    it("strips leading ~ from sort, order, rating, score, and id modifiers", function()
      local branches = engine.normalize_remote("~sort:score ~order:id:desc ~Score:>=50 ~ID:12345 ~rating:general")
      assert.are.equal(1, #branches)
      assert.is_truthy(branches[1]:find("sort:score"))
      assert.is_truthy(branches[1]:find("order:id:desc"))
      assert.is_truthy(branches[1]:find("score:>=50"))
      assert.is_truthy(branches[1]:find("id:12345"))
      assert.is_truthy(branches[1]:find("rating:general"))
      assert.is_falsy(branches[1]:find("~"))
    end)

    it("cleans invalid sort suffixes from remote sort directives", function()
      -- Suffixes like :50 or :1000..1200 are internal pipeline limits, not valid remote booru sort syntax
      assert.are.same({ "sort:score" }, engine.normalize_remote("sort:score:50"))
      assert.are.same({ "sort:score:asc" }, engine.normalize_remote("sort:score:asc:50"))
      assert.are.same({ "sort:score:desc" }, engine.normalize_remote("sort:score:desc:50"))
      assert.are.same({ "sort:id" }, engine.normalize_remote("sort:id:1000..1200"))
      assert.are.same({ "sort:id" }, engine.normalize_remote("sort:id:50.."))
      assert.are.same({ "sort:random" }, engine.normalize_remote("sort:random:1000"))
      assert.are.same({ "order:random" }, engine.normalize_remote("order:random:100"))
      -- Local-only sorts (sort:date, sort:mtime) are omitted from remote booru query
      assert.are.same({ "" }, engine.normalize_remote("sort:date"))
      assert.are.same({ "" }, engine.normalize_remote("sort:mtime"))
      assert.are.same({ "" }, engine.normalize_remote("sort:date:asc"))
    end)

    it("inverts multi-rating queries to negative exclusions (de-Morgan negation)", function()
      local b1 = engine.normalize_remote("zenless_zone_zero ~rating:explicit ~rating:questionable")
      assert.are.equal(1, #b1)
      assert.is_truthy(b1[1]:find("zenless_zone_zero"))
      assert.is_truthy(b1[1]:find("%-rating:general"))
      assert.is_truthy(b1[1]:find("%-rating:sensitive"))
      assert.is_falsy(b1[1]:find("%-rating:explicit"))
      assert.is_falsy(b1[1]:find("%-rating:questionable"))

      local b2 = engine.normalize_remote("rating:q,e")
      assert.are.equal(1, #b2)
      assert.is_truthy(b2[1]:find("%-rating:general"))
      assert.is_truthy(b2[1]:find("%-rating:sensitive"))
    end)

    it("generates concurrent branches for tilde OR tags and deduplicates", function()
      local branches = engine.normalize_remote("zenless_zone_zero ~miku ~miku ~luka ~")
      assert.are.equal(2, #branches)
      assert.are.equal("zenless_zone_zero miku", branches[1])
      assert.are.equal("zenless_zone_zero luka", branches[2])
    end)

    it("strips standalone pipe characters from remote query", function()
      local b1 = engine.normalize_remote("tag |")
      assert.are.same({ "tag" }, b1)
      local b2 = engine.normalize_remote("tag | |")
      assert.are.same({ "tag" }, b2)
    end)

    it("integrates remote branches into QueryPlan during prepare", function()
      local p1 = engine.prepare("tag1 ~luka ~miku")
      assert.are.equal(2, #p1.remote_branches)
      assert.are.equal("tag1 luka", p1.remote_branches[1])
      assert.are.equal("tag1 miku", p1.remote_branches[2])
      assert.are.equal(p1.remote_branches[1], p1.remote_tags)

      local p2 = engine.prepare("zenless_zone_zero sort:id:1000|sort:score:200|sort:random -video")
      assert.is_true(p2.is_pipeline)
      -- First stage is sort:id:1000 -> remote sort is sort:id
      assert.is_truthy(p2.remote_tags:find("zenless_zone_zero"))
      assert.is_truthy(p2.remote_tags:find("%-video"))
      assert.is_truthy(p2.remote_tags:find("sort:id"))
      assert.is_falsy(p2.remote_tags:find("1000"))
      assert.is_falsy(p2.remote_tags:find("200"))

      -- Compatibility aliases
      assert.are.same(p2.stages, p2.pipeline_stages)
      assert.are.same(p2.filters.positive_tags, p2.positive_tags)
      assert.are.same(p2.filters.negative_tags, p2.negative_tags)
      assert.are.equal(p2.dir, p2.target_dir)
    end)
  end)

  describe("engine.matches - tag matching", function()
    it("matches positive tags against post tags, artist, character, and filename stem", function()
      local post = {
        id = 1,
        tags = "hatsune_miku vocaloid 1girl",
        artist = "crypton",
        character = "miku",
        file_url = "/media/sample_image.png",
      }

      assert.is_true(engine.matches(post, "hatsune_miku"))
      assert.is_true(engine.matches(post, "vocaloid"))
      assert.is_true(engine.matches(post, "crypton"))
      assert.is_true(engine.matches(post, "miku"))
      assert.is_true(engine.matches(post, "sample"))
      assert.is_false(engine.matches(post, "kagamine_rin"))
    end)

    it("matches using prepared QueryPlan or raw query string", function()
      local post = { id = 1, tags = "hatsune_miku vocaloid" }
      local plan = engine.prepare("hatsune_miku")
      assert.is_true(engine.matches(post, plan))
      assert.is_true(engine.matches(post, "hatsune_miku"))
    end)

    it("evaluates negative tags and excludes matching posts", function()
      local post = { id = 1, tags = "hatsune_miku vocaloid -video" }
      local post_with_video = { id = 2, tags = "hatsune_miku video" }
      local post_clean = { id = 3, tags = "hatsune_miku vocaloid", file_url = "/media/123.jpg" }

      assert.is_false(engine.matches(post_with_video, "hatsune_miku -video"))
      assert.is_true(engine.matches(post_clean, "hatsune_miku -video"))
    end)

    it("evaluates OR tag disjunction (~tag1 ~tag2 and tag1|tag2)", function()
      local post1 = { id = 1, tags = "hatsune_miku" }
      local post2 = { id = 2, tags = "megurine_luka" }
      local post3 = { id = 3, tags = "kagamine_rin" }

      assert.is_true(engine.matches(post1, "~hatsune_miku ~megurine_luka"))
      assert.is_true(engine.matches(post2, "~hatsune_miku ~megurine_luka"))
      assert.is_false(engine.matches(post3, "~hatsune_miku ~megurine_luka"))

      assert.is_true(engine.matches(post1, "hatsune_miku|megurine_luka"))
      assert.is_true(engine.matches(post2, "hatsune_miku|megurine_luka"))
      assert.is_false(engine.matches(post3, "hatsune_miku|megurine_luka"))
    end)

    it("returns false if post is nil, and true if query is empty/nil", function()
      local post = { id = 1, tags = "hatsune_miku" }
      assert.is_false(engine.matches(nil, "hatsune_miku"))
      assert.is_true(engine.matches(post, nil))
      assert.is_true(engine.matches(post, ""))
      assert.is_true(engine.matches(post, "   "))
    end)
  end)

  describe("engine.matches - rating filtering", function()
    it("matches canonical ratings and single-letter abbreviations", function()
      local post_g = { id = 1, rating = "general" }
      local post_g_alias = { id = 2, rating = "g" }
      local post_e = { id = 3, rating = "explicit" }

      assert.is_true(engine.matches(post_g, "rating:general"))
      assert.is_true(engine.matches(post_g_alias, "rating:general"))
      assert.is_true(engine.matches(post_g, "rating:g"))
      assert.is_false(engine.matches(post_e, "rating:general"))
    end)

    it("evaluates negative rating exclusions", function()
      local post_g = { id = 1, rating = "general" }
      local post_e = { id = 2, rating = "explicit" }

      assert.is_true(engine.matches(post_g, "-rating:explicit"))
      assert.is_false(engine.matches(post_e, "-rating:explicit"))
      assert.is_true(engine.matches(post_g, "-rating:e"))
      assert.is_false(engine.matches(post_e, "-rating:e"))
    end)

    it("evaluates multi-rating disjunctions (rating:q,e or rating:q|e)", function()
      local post_g = { id = 1, rating = "general" }
      local post_q = { id = 2, rating = "questionable" }
      local post_e = { id = 3, rating = "explicit" }

      local q_comma = "rating:q,e"
      assert.is_false(engine.matches(post_g, q_comma))
      assert.is_true(engine.matches(post_q, q_comma))
      assert.is_true(engine.matches(post_e, q_comma))

      local q_pipe = "rating:questionable|explicit"
      assert.is_false(engine.matches(post_g, q_pipe))
      assert.is_true(engine.matches(post_q, q_pipe))
      assert.is_true(engine.matches(post_e, q_pipe))
    end)

    it("handles unhydrated post ratings gracefully (fails positive, passes negative)", function()
      local unhydrated = { id = 1, rating = nil }
      local unhydrated_empty = { id = 2, rating = "" }
      local unhydrated_question = { id = 3, rating = "?" }

      assert.is_false(engine.matches(unhydrated, "rating:general"))
      assert.is_false(engine.matches(unhydrated_empty, "rating:general"))
      assert.is_false(engine.matches(unhydrated_question, "rating:general"))

      assert.is_true(engine.matches(unhydrated, "-rating:explicit"))
      assert.is_true(engine.matches(unhydrated_empty, "-rating:explicit"))
      assert.is_true(engine.matches(unhydrated_question, "-rating:explicit"))
    end)
  end)

  describe("engine.matches - score filtering", function()
    it("evaluates relational operators (>, >=, <, <=, ==, bare)", function()
      local post_low = { id = 1, score = 5 }
      local post_mid = { id = 2, score = 50 }
      local post_high = { id = 3, score = 100 }

      assert.is_true(engine.matches(post_high, "score:>50"))
      assert.is_false(engine.matches(post_mid, "score:>50"))

      assert.is_true(engine.matches(post_high, "score:>=50"))
      assert.is_true(engine.matches(post_mid, "score:>=50"))
      assert.is_false(engine.matches(post_low, "score:>=50"))

      assert.is_true(engine.matches(post_low, "score:<50"))
      assert.is_false(engine.matches(post_mid, "score:<50"))

      assert.is_true(engine.matches(post_low, "score:<=50"))
      assert.is_true(engine.matches(post_mid, "score:<=50"))
      assert.is_false(engine.matches(post_high, "score:<=50"))

      assert.is_true(engine.matches(post_mid, "score:==50"))
      assert.is_true(engine.matches(post_mid, "score:50"))
      assert.is_false(engine.matches(post_low, "score:==50"))
    end)

    it("handles unhydrated post scores (defaults to 0)", function()
      local post_nil = { id = 1, score = nil }
      assert.is_true(engine.matches(post_nil, "score:<=0"))
      assert.is_true(engine.matches(post_nil, "score:==0"))
      assert.is_false(engine.matches(post_nil, "score:>0"))
      assert.is_false(engine.matches(post_nil, "score:>=10"))
    end)

    it("resolves score from disk metadata cache when in-memory score is nil", function()
      local post = { id = 98765, score = nil }
      local meta_path = util.meta_cache_path(post.id)
      util.write_json(meta_path, { id = 98765, score = 88 })

      assert.is_true(engine.matches(post, "score:>=80"))
      assert.is_false(engine.matches(post, "score:>90"))
      assert.are.equal(88, post.score)

      -- Cleanup
      pcall(vim.fn.delete, meta_path)
    end)
  end)

  describe("engine.matches - artist, character, and ID filtering", function()
    it("evaluates explicit artist modifier (artist:name and -artist:name)", function()
      local post_artist = { id = 1, artist = "ke-ta" }
      local post_other = { id = 2, artist = "huke" }

      assert.is_true(engine.matches(post_artist, "artist:ke-ta"))
      assert.is_false(engine.matches(post_other, "artist:ke-ta"))

      assert.is_false(engine.matches(post_artist, "-artist:ke-ta"))
      assert.is_true(engine.matches(post_other, "-artist:ke-ta"))
    end)

    it("evaluates explicit character modifier (character:name and -character:name)", function()
      local post_char = { id = 1, character = "hatsune_miku" }
      local post_other = { id = 2, character = "megurine_luka" }

      assert.is_true(engine.matches(post_char, "character:hatsune_miku"))
      assert.is_false(engine.matches(post_other, "character:hatsune_miku"))

      assert.is_false(engine.matches(post_char, "-character:hatsune_miku"))
      assert.is_true(engine.matches(post_other, "-character:hatsune_miku"))
    end)

    it("evaluates post ID filter (id:digits)", function()
      local post1 = { id = "12345" }
      local post2 = { id = 67890 }

      assert.is_true(engine.matches(post1, "id:12345"))
      assert.is_false(engine.matches(post2, "id:12345"))
      assert.is_true(engine.matches(post2, "id:67890"))
    end)
  end)

  describe("engine.evaluate - dataset filtering", function()
    local sample_posts

    before_each(function()
      sample_posts = {
        { id = 1, tags = "hatsune_miku vocaloid", rating = "general", score = 100, file_url = "/a.jpg" },
        { id = 2, tags = "megurine_luka vocaloid", rating = "general", score = 50, file_url = "/b.jpg" },
        { id = 3, tags = "kagamine_rin vocaloid video", rating = "sensitive", score = 20, file_url = "/c.jpg" },
        { id = 4, tags = "kasane_teto utau", rating = "general", score = 10, file_url = "/d.jpg" },
      }
    end)

    it("filters posts by positive and negative tags", function()
      local res = engine.evaluate(sample_posts, "vocaloid -video")
      assert.are.equal(2, #res)
      assert.are.equal(1, res[1].id)
      assert.are.equal(2, res[2].id)
    end)

    it("filters posts by rating and score criteria", function()
      local res = engine.evaluate(sample_posts, "rating:general score:>=50")
      assert.are.equal(2, #res)
      assert.are.equal(1, res[1].id)
      assert.are.equal(2, res[2].id)
    end)

    it("accepts prepared QueryPlan or raw query string", function()
      local plan = engine.prepare("kasane_teto")
      local res1 = engine.evaluate(sample_posts, plan)
      local res2 = engine.evaluate(sample_posts, "kasane_teto")
      assert.are.equal(1, #res1)
      assert.are.equal(4, res1[1].id)
      assert.are.same(res1, res2)
    end)

    it("does not mutate the input posts array", function()
      local original_count = #sample_posts
      local res = engine.evaluate(sample_posts, "rating:sensitive")
      assert.are.equal(1, #res)
      assert.are.equal(original_count, #sample_posts)
    end)

    it("handles nil or empty posts and queries gracefully", function()
      assert.are.same({}, engine.evaluate(nil, "miku"))
      assert.are.same({}, engine.evaluate({}, "miku"))
      local res_all = engine.evaluate(sample_posts, nil)
      assert.are.equal(#sample_posts, #res_all)
      local res_empty = engine.evaluate(sample_posts, "   ")
      assert.are.equal(#sample_posts, #res_empty)
    end)
  end)

  describe("engine.evaluate - sorting & deterministic tie-breaking", function()
    it("sorts by score descending and ascending", function()
      local posts = {
        { id = 1, score = 10 },
        { id = 2, score = 50 },
        { id = 3, score = 25 },
      }

      local desc = engine.evaluate(posts, "sort:score")
      assert.are.equal(2, desc[1].id)
      assert.are.equal(3, desc[2].id)
      assert.are.equal(1, desc[3].id)

      local asc = engine.evaluate(posts, "sort:score:asc")
      assert.are.equal(1, asc[1].id)
      assert.are.equal(3, asc[2].id)
      assert.are.equal(2, asc[3].id)
    end)

    it("sorts by id descending and ascending", function()
      local posts = {
        { id = 100 },
        { id = 500 },
        { id = 250 },
      }

      local desc = engine.evaluate(posts, "sort:id")
      assert.are.equal(500, desc[1].id)
      assert.are.equal(250, desc[2].id)
      assert.are.equal(100, desc[3].id)

      local asc = engine.evaluate(posts, "sort:id:asc")
      assert.are.equal(100, asc[1].id)
      assert.are.equal(250, asc[2].id)
      assert.are.equal(500, asc[3].id)
    end)

    it("sorts by date / mtime descending and ascending", function()
      local posts = {
        { id = 1, _mtime = 1000 },
        { id = 2, _mtime = 3000 },
        { id = 3, _mtime = 2000 },
      }

      local desc = engine.evaluate(posts, "sort:date")
      assert.are.equal(2, desc[1].id)
      assert.are.equal(3, desc[2].id)
      assert.are.equal(1, desc[3].id)

      local asc = engine.evaluate(posts, "sort:mtime:asc")
      assert.are.equal(1, asc[1].id)
      assert.are.equal(3, asc[2].id)
      assert.are.equal(2, asc[3].id)
    end)

    it("breaks ties deterministically on post ID desc, then file_url asc", function()
      local posts = {
        { id = 10, score = 50, file_url = "/z.jpg" },
        { id = 30, score = 50, file_url = "/a.jpg" },
        { id = 20, score = 50, file_url = "/m.jpg" },
      }

      local res = engine.evaluate(posts, "sort:score")
      -- All have score 50; tie-breaker: id desc -> 30, 20, 10
      assert.are.equal(30, res[1].id)
      assert.are.equal(20, res[2].id)
      assert.are.equal(10, res[3].id)

      -- When ID is also identical, tie-breaker: file_url asc
      local identical_ids = {
        { id = 10, score = 50, file_url = "/z.jpg" },
        { id = 10, score = 50, file_url = "/a.jpg" },
        { id = 10, score = 50, file_url = "/m.jpg" },
      }

      local res_url = engine.evaluate(identical_ids, "sort:score")
      assert.are.equal("/a.jpg", res_url[1].file_url)
      assert.are.equal("/m.jpg", res_url[2].file_url)
      assert.are.equal("/z.jpg", res_url[3].file_url)
    end)

    it("randomly shuffles array with sort:random while preserving all items", function()
      local posts = {}
      for i = 1, 50 do
        table.insert(posts, { id = i, score = i })
      end

      local shuffled = engine.evaluate(posts, "sort:random")
      assert.are.equal(50, #shuffled)

      local seen = {}
      for _, p in ipairs(shuffled) do
        seen[p.id] = true
      end
      for i = 1, 50 do
        assert.is_true(seen[i])
      end
    end)
  end)

  describe("engine.evaluate - pipeline transforms & slicing", function()
    it("slices bare ranges with default id desc order (e.g. 2..4)", function()
      local posts = {
        { id = 1 },
        { id = 2 },
        { id = 3 },
        { id = 4 },
        { id = 5 },
      }

      -- Default id desc: [5, 4, 3, 2, 1] -> slice 2..4 -> [4, 3, 2]
      local res = engine.evaluate(posts, "2..4")
      assert.are.equal(3, #res)
      assert.are.equal(4, res[1].id)
      assert.are.equal(3, res[2].id)
      assert.are.equal(2, res[3].id)

      -- Explicit id asc: [1, 2, 3, 4, 5] -> slice 2..4 -> [2, 3, 4]
      local res_asc = engine.evaluate(posts, "sort:id:asc:2..4")
      assert.are.equal(3, #res_asc)
      assert.are.equal(2, res_asc[1].id)
      assert.are.equal(3, res_asc[2].id)
      assert.are.equal(4, res_asc[3].id)
    end)

    it("slices open-ended start range (e.g. 3..)", function()
      local posts = {
        { id = 1 },
        { id = 2 },
        { id = 3 },
        { id = 4 },
        { id = 5 },
      }

      -- Default id desc: [5, 4, 3, 2, 1] -> slice 3.. -> [3, 2, 1]
      local res = engine.evaluate(posts, "3..")
      assert.are.equal(3, #res)
      assert.are.equal(3, res[1].id)
      assert.are.equal(1, res[3].id)

      -- Explicit id asc: [1, 2, 3, 4, 5] -> slice 3.. -> [3, 4, 5]
      local res_asc = engine.evaluate(posts, "sort:id:asc:3..")
      assert.are.equal(3, #res_asc)
      assert.are.equal(3, res_asc[1].id)
      assert.are.equal(5, res_asc[3].id)
    end)

    it("slices open-ended end range (e.g. ..3) without dropping the first post", function()
      local posts = {
        { id = 1 },
        { id = 2 },
        { id = 3 },
        { id = 4 },
        { id = 5 },
      }

      -- Default id desc: [5, 4, 3, 2, 1] -> slice ..3 -> [5, 4, 3]
      local res = engine.evaluate(posts, "..3")
      assert.are.equal(3, #res)
      assert.are.equal(5, res[1].id)
      assert.are.equal(3, res[3].id)

      -- Explicit id asc: [1, 2, 3, 4, 5] -> slice ..3 -> [1, 2, 3]
      local res_asc = engine.evaluate(posts, "sort:id:asc:..3")
      assert.are.equal(3, #res_asc)
      assert.are.equal(1, res_asc[1].id)
      assert.are.equal(3, res_asc[3].id)
    end)

    it("slices bare limit counts after pipe (e.g. tag | 2)", function()
      local posts = {
        { id = 1, tags = "miku" },
        { id = 2, tags = "miku" },
        { id = 3, tags = "miku" },
        { id = 4, tags = "miku" },
      }

      -- Default id desc: [4, 3, 2, 1] -> limit 2 -> [4, 3]
      local res = engine.evaluate(posts, "miku | 2")
      assert.are.equal(2, #res)
      assert.are.equal(4, res[1].id)
      assert.are.equal(3, res[2].id)
    end)

    it("slices offset and limit combinations (e.g. offset:2 limit:2)", function()
      local posts = {
        { id = 1 },
        { id = 2 },
        { id = 3 },
        { id = 4 },
        { id = 5 },
      }

      -- offset:2 skips 1 and 2, starts at index 3; limit:2 takes 2 items -> items 3 and 4
      local res = engine.evaluate(posts, "offset:2 limit:2")
      assert.are.equal(2, #res)
      assert.are.equal(3, res[1].id)
      assert.are.equal(4, res[2].id)
    end)

    it("handles out-of-bounds offset safely by returning empty list", function()
      local posts = { { id = 1 }, { id = 2 } }
      local res = engine.evaluate(posts, "offset:10")
      assert.are.same({}, res)
    end)

    it("evaluates complete chain: criteria filtering + sorting + multi-stage slicing", function()
      local posts = {
        { id = 1, tags = "miku", score = 10 },
        { id = 2, tags = "miku", score = 90 },
        { id = 3, tags = "miku video", score = 100 }, -- excluded by -video
        { id = 4, tags = "miku", score = 50 },
        { id = 5, tags = "miku", score = 30 },
        { id = 6, tags = "luka", score = 80 }, -- excluded by miku tag
      }

      -- Filter: miku -video -> ids 1 (10), 2 (90), 4 (50), 5 (30)
      -- Stage 1: sort:score -> ids 2 (90), 4 (50), 5 (30), 1 (10)
      -- Stage 2: 1..2 -> ids 2 (90), 4 (50)
      local res = engine.evaluate(posts, "miku -video | sort:score | 1..2")
      assert.are.equal(2, #res)
      assert.are.equal(2, res[1].id)
      assert.are.equal(4, res[2].id)
    end)
  end)

  describe("engine.prepare - has_filter root flag", function()
    it("sets has_filter = false when no filter criteria is present", function()
      assert.is_false(engine.prepare(nil).has_filter)
      assert.is_false(engine.prepare("").has_filter)
      assert.is_false(engine.prepare("   ").has_filter)
      assert.is_false(engine.prepare("local:").has_filter)
      assert.is_false(engine.prepare("local: sort:date").has_filter)
      assert.is_false(engine.prepare("local:/some/dir sort:score").has_filter)
      assert.is_false(engine.prepare("sort:score").has_filter)
      assert.is_false(engine.prepare("sort:random").has_filter)
      assert.is_false(engine.prepare("| sort:score:50").has_filter)
      assert.is_false(engine.prepare("sort:id:1000..1200").has_filter)
    end)

    it("sets has_filter = true whenever any filter criteria exists", function()
      assert.is_true(engine.prepare("hatsune_miku").has_filter)
      assert.is_true(engine.prepare("local: hatsune_miku").has_filter)
      assert.is_true(engine.prepare("-video").has_filter)
      assert.is_true(engine.prepare("rating:general").has_filter)
      assert.is_true(engine.prepare("-rating:explicit").has_filter)
      assert.is_true(engine.prepare("score:>=50").has_filter)
      assert.is_true(engine.prepare("artist:some_artist").has_filter)
      assert.is_true(engine.prepare("-artist:some_artist").has_filter)
      assert.is_true(engine.prepare("character:some_char").has_filter)
      assert.is_true(engine.prepare("-character:some_char").has_filter)
      assert.is_true(engine.prepare("id:12345").has_filter)
      assert.is_true(engine.prepare("~hatsune_miku").has_filter)
      assert.is_true(engine.prepare("tag1|tag2").has_filter)
      assert.is_true(engine.prepare("miku | sort:score:50").has_filter)
    end)
  end)

  describe("engine.has_random_modifier", function()
    it("detects sort:random and order:random directives", function()
      assert.is_true(engine.has_random_modifier("sort:random"))
      assert.is_true(engine.has_random_modifier("order:random"))
      assert.is_true(engine.has_random_modifier("Sort:Random"))
      assert.is_true(engine.has_random_modifier("tag sort:random:100"))
      assert.is_true(engine.has_random_modifier("local: order:random:50"))
      assert.is_false(engine.has_random_modifier("sort:score"))
      assert.is_false(engine.has_random_modifier("tag"))
      assert.is_false(engine.has_random_modifier(""))
      assert.is_false(engine.has_random_modifier(nil))
    end)
  end)

  describe("engine.execute_pipeline - offset and limit bounds", function()
    local sample_items

    before_each(function()
      sample_items = {}
      for i = 1, 20 do
        table.insert(sample_items, { id = i, score = i * 10 })
      end
    end)

    it("slices correctly with single stage containing both offset and limit (not is_range)", function()
      -- offset: 10, limit: 5 -> skips first 10 items (1..10), takes next 5 items (11..15)
      local stages = { { offset = 10, limit = 5, is_range = false } }
      local res = engine.execute_pipeline(sample_items, stages)
      assert.are.equal(5, #res)
      assert.are.equal(11, res[1].id)
      assert.are.equal(15, res[5].id)
    end)

    it("slices correctly with bounded range (is_range = true)", function()
      -- range 10..15 -> items from index 10 to 15 (inclusive, 6 items)
      local stages = { { offset = 10, limit = 15, is_range = true } }
      local res = engine.execute_pipeline(sample_items, stages)
      assert.are.equal(6, #res)
      assert.are.equal(10, res[1].id)
      assert.are.equal(15, res[6].id)
    end)

    it("slices correctly with open-ended offset range (is_range = true, no limit)", function()
      -- range 15.. -> items from 15 to end (6 items: 15..20)
      local stages = { { offset = 15, is_range = true } }
      local res = engine.execute_pipeline(sample_items, stages)
      assert.are.equal(6, #res)
      assert.are.equal(15, res[1].id)
      assert.are.equal(20, res[6].id)
    end)

    it("slices correctly with open-ended limit range (..5, is_range = true)", function()
      -- range ..5 -> items from 1 to 5
      local stages = { { offset = 1, limit = 5, is_range = true } }
      local res = engine.execute_pipeline(sample_items, stages)
      assert.are.equal(5, #res)
      assert.are.equal(1, res[1].id)
      assert.are.equal(5, res[5].id)
    end)

    it("handles limit larger than dataset without off-by-one errors", function()
      local stages = { { offset = 15, limit = 100, is_range = false } }
      local res = engine.execute_pipeline(sample_items, stages)
      assert.are.equal(5, #res) -- only 5 items remaining (16..20)
      assert.are.equal(16, res[1].id)
      assert.are.equal(20, res[5].id)
    end)
  end)
end)
