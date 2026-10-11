local parse = require("gelbooru.query.parse")
local pipeline = require("gelbooru.query.pipeline")
local sort = require("gelbooru.query.sort")
local filter = require("gelbooru.query.filter")

local M = {
  -- Submodule references
  parse = parse,
  pipeline = pipeline,
  sort = sort,
  filter = filter,

  -- Parsing API
  normalize_rating = parse.normalize_rating,
  tokenize_query = parse.tokenize_query,
  is_dir_token = parse.is_dir_token,
  parse_limit_or_range = parse.parse_limit_or_range,
  parse_stage = parse.parse_stage,
  parse_sort_token = parse.parse_sort_token,
  parse_query = parse.parse_query,
  parse_local_query = parse.parse_local_query,
  parse_tags = parse.parse_tags,

  -- Pipeline API
  split_by_pipeline_pipe = pipeline.split_by_pipeline_pipe,
  parse_pipeline = pipeline.parse_pipeline,
  execute_pipeline = pipeline.execute_pipeline,

  -- Sorting API
  sort_posts = sort.sort_posts,
  get_post_score = sort.get_post_score,
  get_post_mtime = sort.get_post_mtime,

  -- Filtering API
  matches_post = filter.matches_post,
  matches_query = filter.matches_query,
  filter_posts = filter.filter_posts,
}

return M
