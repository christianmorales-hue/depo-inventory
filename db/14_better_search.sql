-- Better fuzzy search.
--
-- The old function used similarity() across whole strings, which failed on
-- short queries against long descriptions - "pixo" against a 40-char string
-- scored below the threshold. This version:
--
--   1. Uses word_similarity() instead, which scores the query against the
--      best matching WORD in the target, not the whole thing.
--   2. Adds a big boost for a plain substring match, so any query that
--      literally appears in the text always wins.
--   3. Splits multi-word queries and rewards items that match any word.
--   4. Lowers the threshold. 0.25 was tuned for long queries; short queries
--      like "pixo" and "capo" barely score above 0.15 even when they are
--      obviously the right item.

CREATE OR REPLACE FUNCTION search_items(q text, max_rows int DEFAULT 20)
RETURNS TABLE (item_id bigint, sku text, description text, score real)
LANGUAGE sql STABLE AS $$
  WITH
  q AS (SELECT norm_text(coalesce(q,'')) AS n),
  q_words AS (
    SELECT unnest(regexp_split_to_array((SELECT n FROM q), '\s+')) AS w
  )
  SELECT i.item_id, i.sku, i.description, m.score
  FROM item i
  LEFT JOIN item_alias a ON a.item_id = i.item_id
  CROSS JOIN LATERAL (
    SELECT GREATEST(
      -- substring hit anywhere in the text = big win
      CASE WHEN norm_text(i.description) LIKE '%' || (SELECT n FROM q) || '%'
           THEN 1.0 ELSE 0 END,
      CASE WHEN norm_text(coalesce(i.part_code,'')) LIKE '%' || (SELECT n FROM q) || '%'
           THEN 1.0 ELSE 0 END,
      CASE WHEN a.alias_norm LIKE '%' || (SELECT n FROM q) || '%'
           THEN 1.0 ELSE 0 END,
      -- word-level fuzzy match: query vs best-matching word in the text
      word_similarity((SELECT n FROM q), norm_text(i.description)),
      word_similarity((SELECT n FROM q), norm_text(coalesce(i.part_code,''))),
      coalesce(word_similarity((SELECT n FROM q), a.alias_norm), 0),
      -- last resort: any word of the query matches any word in the target
      coalesce(
        (SELECT max(word_similarity(qw.w, norm_text(i.description)))
         FROM q_words qw WHERE length(qw.w) >= 3), 0)
    ) AS score
  ) m
  WHERE i.is_active AND m.score > 0.35
  GROUP BY i.item_id, m.score
  ORDER BY m.score DESC, i.description
  LIMIT max_rows;
$$;

-- word_similarity relies on the trigram GIN index using the right operator
-- class. Make sure the indexes exist and are fresh.
DROP INDEX IF EXISTS item_desc_trgm;
DROP INDEX IF EXISTS item_code_trgm;
CREATE INDEX item_desc_trgm ON item USING gin (norm_text(description) gin_trgm_ops);
CREATE INDEX item_code_trgm ON item USING gin (norm_text(coalesce(part_code,'')) gin_trgm_ops);

DROP INDEX IF EXISTS alias_norm_trgm;
CREATE INDEX alias_norm_trgm ON item_alias USING gin (alias_norm gin_trgm_ops);

ANALYZE item;
ANALYZE item_alias;
