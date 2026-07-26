-- Fix: an item with multiple aliases was appearing multiple times in search,
-- because each alias produced its own score row and GROUP BY item_id, score
-- kept them all. Now we compute one best score per item.

CREATE OR REPLACE FUNCTION search_items(q text, max_rows int DEFAULT 20)
RETURNS TABLE (item_id bigint, sku text, description text, score real)
LANGUAGE sql STABLE AS $$
  WITH
  q AS (SELECT norm_text(coalesce(q,'')) AS n),
  q_words AS (
    SELECT unnest(regexp_split_to_array((SELECT n FROM q), '\s+')) AS w
  ),
  -- One row per item: its best matching score across all of its aliases.
  scored AS (
    SELECT i.item_id, i.sku, i.description,
           max(GREATEST(
             CASE WHEN norm_text(coalesce(i.part_code,'')) LIKE (SELECT n FROM q) || '%'
                  THEN 1.20 ELSE 0 END,
             CASE WHEN norm_text(coalesce(i.part_code,'')) LIKE '%' || (SELECT n FROM q) || '%'
                  THEN 1.10 ELSE 0 END,
             CASE WHEN norm_text(i.description) LIKE '%' || (SELECT n FROM q) || '%'
                  THEN 1.00 ELSE 0 END,
             CASE WHEN a.alias_norm LIKE '%' || (SELECT n FROM q) || '%'
                  THEN 1.00 ELSE 0 END,
             0.90 * word_similarity((SELECT n FROM q),
                                    norm_text(coalesce(i.part_code,''))),
             0.60 * word_similarity((SELECT n FROM q), norm_text(i.description)),
             0.60 * coalesce(word_similarity((SELECT n FROM q), a.alias_norm), 0),
             0.60 * coalesce(
               (SELECT max(word_similarity(qw.w, norm_text(i.description)))
                FROM q_words qw WHERE length(qw.w) >= 3), 0)
           )) AS score,
           min(length(coalesce(i.part_code, 'zzzzzz'))) AS code_len
    FROM item i
    LEFT JOIN item_alias a ON a.item_id = i.item_id
    WHERE i.is_active
    GROUP BY i.item_id, i.sku, i.description
  )
  SELECT item_id, sku, description, score
  FROM scored
  WHERE score > 0.35
  ORDER BY score DESC, code_len, description
  LIMIT max_rows;
$$;

ANALYZE item;
ANALYZE item_alias;
