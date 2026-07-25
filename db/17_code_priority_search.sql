-- Code-first search.
--
-- People search a description with words ("espejo corolla"). They search a
-- code with letters and dashes ("BU-sur", "212-19", "870163"). This version
-- gives part_code matches priority so that typing part of a code brings the
-- right item first, without hurting word searches.
--
-- Scoring buckets, highest wins:
--   1.20  part_code starts with the query (e.g. "BU-sur" -> "BU-SURF-F-L")
--   1.10  query is a substring of part_code (matches anywhere)
--   1.00  query is a substring of description or alias
--   0.90  fuzzy match on part_code
--   0.60  fuzzy word_similarity match on description or alias

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
      -- Prefix match on code: strongest signal.
      CASE WHEN norm_text(coalesce(i.part_code,'')) LIKE (SELECT n FROM q) || '%'
           THEN 1.20 ELSE 0 END,
      -- Substring on code.
      CASE WHEN norm_text(coalesce(i.part_code,'')) LIKE '%' || (SELECT n FROM q) || '%'
           THEN 1.10 ELSE 0 END,
      -- Substring on description or alias.
      CASE WHEN norm_text(i.description) LIKE '%' || (SELECT n FROM q) || '%'
           THEN 1.00 ELSE 0 END,
      CASE WHEN a.alias_norm LIKE '%' || (SELECT n FROM q) || '%'
           THEN 1.00 ELSE 0 END,
      -- Fuzzy on code (typos in the code).
      0.90 * word_similarity((SELECT n FROM q),
                             norm_text(coalesce(i.part_code,''))),
      -- Fuzzy on description or alias.
      0.60 * word_similarity((SELECT n FROM q), norm_text(i.description)),
      0.60 * coalesce(word_similarity((SELECT n FROM q), a.alias_norm), 0),
      -- Last resort: any word of the query fuzzy-matches any word in the text.
      0.60 * coalesce(
        (SELECT max(word_similarity(qw.w, norm_text(i.description)))
         FROM q_words qw WHERE length(qw.w) >= 3), 0)
    ) AS score
  ) m
  WHERE i.is_active AND m.score > 0.35
  GROUP BY i.item_id, m.score
  -- Ties broken by: shorter part_code first (so BU-SURF-F-L wins over a
  -- longer code that happens to contain the same substring).
  ORDER BY m.score DESC,
           length(coalesce(i.part_code, 'zzzzzz')),
           i.description
  LIMIT max_rows;
$$;

ANALYZE item;
ANALYZE item_alias;
