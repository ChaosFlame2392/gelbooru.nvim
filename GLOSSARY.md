# gelbooru.nvim Domain Glossary

Domain and architectural language for the gelbooru.nvim imageboard browser and local media library plugin.

## Core Domain Concepts

**Post**:
A single booru record containing numeric ID, media URLs (original, sample, preview), dimensional metadata, tags, rating, and score.
_Avoid_: item, image entry, media record

**Candidate Pool**:
The in-memory collection of posts retrieved for a query, cached during an active session with time-to-live expiration.
_Avoid_: cache pool, search results array

**Query Plan**:
The normalized, structured representation of user search tokens, negative exclusions, rating constraints, sort directives, and pipeline stages.
_Avoid_: parsed query, search AST

## Presentation & Media Subsystem

**Terminal Graphics Engine**:
The module responsible for rendering visual assets into floating Neovim windows across diverse terminal graphics protocols.
_Avoid_: image viewer, canvas renderer, picture component

**Media Inspector**:
A pure, deterministic binary parser that reads image dimensions and format completion directly from file headers without external processes.
_Avoid_: header extractor, metadata parser

**Media Transcoder**:
An asynchronous adapter executing OS child processes (such as ffmpeg) to extract video thumbnails and convert animation frames.
_Avoid_: video processor, converter service

**Asset Pipeline**:
The unified asynchronous retrieval and caching coordinator that manages network downloads, rate limiting, and disk readiness for posts.
_Avoid_: download manager, prefetcher queue
