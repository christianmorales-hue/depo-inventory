--
-- PostgreSQL database dump
--

\restrict vipyhzlvPprbVNaymsgUsruAWBepdGbdkCK6kWo9zTzUY8mXv5XnXOOTMOIdcfo

-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 16.14 (Debian 16.14-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: unaccent; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;


--
-- Name: EXTENSION unaccent; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION unaccent IS 'text search dictionary that removes accents';


--
-- Name: item_condition; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.item_condition AS ENUM (
    'good',
    'defective'
);


--
-- Name: movement_reason; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.movement_reason AS ENUM (
    'opening',
    'purchase',
    'sale',
    'transfer_in',
    'transfer_out',
    'adjustment',
    'defect'
);


--
-- Name: stocktake_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.stocktake_status AS ENUM (
    'open',
    'closed',
    'cancelled'
);


--
-- Name: close_stocktake(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.close_stocktake(p_stocktake bigint, p_by text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE v_branch smallint; v_rows integer;
BEGIN
  SELECT branch_id INTO v_branch FROM stocktake
   WHERE stocktake_id = p_stocktake AND status = 'open' FOR UPDATE;
  IF v_branch IS NULL THEN
    RAISE EXCEPTION 'stocktake % is not open', p_stocktake;
  END IF;

  INSERT INTO stock_movement (item_id, branch_id, qty_delta, condition, reason,
                              note, created_by)
  SELECT l.item_id, v_branch,
         l.counted_qty - coalesce(l.expected_qty, 0),
         l.condition, 'adjustment',
         format('stocktake %s: expected %s, counted %s',
                p_stocktake, coalesce(l.expected_qty, 0), l.counted_qty),
         coalesce(p_by, l.counted_by)
    FROM stocktake_line l
   WHERE l.stocktake_id = p_stocktake
     AND l.counted_qty - coalesce(l.expected_qty, 0) <> 0;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  UPDATE stocktake SET status = 'closed', closed_at = now()
   WHERE stocktake_id = p_stocktake;
  RETURN v_rows;
END $$;


--
-- Name: f_unaccent(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.f_unaccent(text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $_$ SELECT public.unaccent('public.unaccent'::regdictionary, $1) $_$;


--
-- Name: norm_text(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.norm_text(text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $_$ SELECT regexp_replace(upper(f_unaccent($1)), '[^A-Z0-9]+', ' ', 'g') $_$;


--
-- Name: record_count(bigint, bigint, integer, text, public.item_condition); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_count(p_stocktake bigint, p_item bigint, p_qty integer, p_by text DEFAULT NULL::text, p_condition public.item_condition DEFAULT 'good'::public.item_condition) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE v_branch smallint; v_expected integer;
BEGIN
  SELECT branch_id INTO v_branch FROM stocktake
   WHERE stocktake_id = p_stocktake AND status = 'open';
  IF v_branch IS NULL THEN
    RAISE EXCEPTION 'stocktake % is not open', p_stocktake;
  END IF;

  SELECT coalesce(sum(qty_delta), 0) INTO v_expected
    FROM stock_movement
   WHERE item_id = p_item AND branch_id = v_branch AND condition = p_condition;

  INSERT INTO stocktake_line (stocktake_id, item_id, condition, counted_qty,
                              expected_qty, counted_by)
  VALUES (p_stocktake, p_item, p_condition, p_qty, v_expected, p_by)
  ON CONFLICT (stocktake_id, item_id, condition) DO UPDATE
    SET counted_qty = excluded.counted_qty,
        expected_qty = excluded.expected_qty,
        counted_at = now(),
        counted_by = excluded.counted_by;
END $$;


--
-- Name: search_items(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_items(q text, max_rows integer DEFAULT 20) RETURNS TABLE(item_id bigint, sku text, description text, score real)
    LANGUAGE sql STABLE
    AS $$
  SELECT i.item_id, i.sku, i.description,
         GREATEST(
           similarity(norm_text(i.description), norm_text(q)),
           similarity(norm_text(coalesce(i.part_code,'')), norm_text(q)),
           coalesce(MAX(similarity(a.alias_norm, norm_text(q))), 0)
         ) AS score
  FROM item i
  LEFT JOIN item_alias a ON a.item_id = i.item_id
  WHERE i.is_active
  GROUP BY i.item_id
  HAVING GREATEST(
           similarity(norm_text(i.description), norm_text(q)),
           similarity(norm_text(coalesce(i.part_code,'')), norm_text(q)),
           coalesce(MAX(similarity(a.alias_norm, norm_text(q))), 0)
         ) > 0.25
  ORDER BY score DESC
  LIMIT max_rows;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: branch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch (
    branch_id smallint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_real boolean DEFAULT true NOT NULL
);


--
-- Name: branch_branch_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.branch_branch_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: branch_branch_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.branch_branch_id_seq OWNED BY public.branch.branch_id;


--
-- Name: category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.category (
    category_id smallint NOT NULL,
    name text NOT NULL
);


--
-- Name: category_category_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.category_category_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: category_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.category_category_id_seq OWNED BY public.category.category_id;


--
-- Name: item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item (
    item_id bigint NOT NULL,
    sku text NOT NULL,
    part_code text,
    base_code text,
    side character(1),
    category_id smallint,
    description text NOT NULL,
    unit_price numeric(12,2),
    legacy_row_id integer,
    needs_review boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT item_side_check CHECK ((side = ANY (ARRAY['L'::bpchar, 'R'::bpchar]))),
    CONSTRAINT item_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


--
-- Name: item_alias; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_alias (
    alias_id bigint NOT NULL,
    item_id bigint NOT NULL,
    alias text NOT NULL,
    alias_norm text GENERATED ALWAYS AS (public.norm_text(alias)) STORED,
    source text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: item_alias_alias_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.item_alias_alias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: item_alias_alias_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.item_alias_alias_id_seq OWNED BY public.item_alias.alias_id;


--
-- Name: item_item_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.item_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: item_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.item_item_id_seq OWNED BY public.item.item_id;


--
-- Name: stock_movement; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_movement (
    movement_id bigint NOT NULL,
    item_id bigint NOT NULL,
    branch_id smallint NOT NULL,
    qty_delta integer NOT NULL,
    condition public.item_condition DEFAULT 'good'::public.item_condition NOT NULL,
    reason public.movement_reason NOT NULL,
    note text,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    CONSTRAINT stock_movement_qty_delta_check CHECK ((qty_delta <> 0))
);


--
-- Name: stock_movement_movement_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stock_movement_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stock_movement_movement_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stock_movement_movement_id_seq OWNED BY public.stock_movement.movement_id;


--
-- Name: stock_on_hand; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.stock_on_hand AS
 SELECT item_id,
    branch_id,
    condition,
    (sum(qty_delta))::integer AS qty
   FROM public.stock_movement
  GROUP BY item_id, branch_id, condition
 HAVING (sum(qty_delta) <> 0);


--
-- Name: stocktake; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stocktake (
    stocktake_id bigint NOT NULL,
    branch_id smallint NOT NULL,
    label text NOT NULL,
    status public.stocktake_status DEFAULT 'open'::public.stocktake_status NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    created_by text
);


--
-- Name: stocktake_line; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stocktake_line (
    stocktake_id bigint NOT NULL,
    item_id bigint NOT NULL,
    condition public.item_condition DEFAULT 'good'::public.item_condition NOT NULL,
    counted_qty integer NOT NULL,
    expected_qty integer,
    note text,
    counted_at timestamp with time zone DEFAULT now() NOT NULL,
    counted_by text,
    CONSTRAINT stocktake_line_counted_qty_check CHECK ((counted_qty >= 0))
);


--
-- Name: stocktake_stocktake_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stocktake_stocktake_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stocktake_stocktake_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stocktake_stocktake_id_seq OWNED BY public.stocktake.stocktake_id;


--
-- Name: v_availability; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_availability AS
 SELECT i.sku,
    i.part_code,
    i.description,
    i.side,
    i.unit_price,
    b.name AS branch,
    s.condition,
    s.qty
   FROM ((public.stock_on_hand s
     JOIN public.item i ON ((i.item_id = s.item_id)))
     JOIN public.branch b ON ((b.branch_id = s.branch_id)));


--
-- Name: v_count_sheet; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_count_sheet AS
 SELECT b.code AS branch,
    i.sku,
    i.part_code,
    i.side,
    i.description,
    COALESCE(s.qty, 0) AS expected_qty
   FROM ((public.branch b
     CROSS JOIN public.item i)
     LEFT JOIN public.stock_on_hand s ON (((s.item_id = i.item_id) AND (s.branch_id = b.branch_id) AND (s.condition = 'good'::public.item_condition))))
  WHERE (i.is_active AND b.is_real)
  ORDER BY b.code, i.description;


--
-- Name: branch branch_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch ALTER COLUMN branch_id SET DEFAULT nextval('public.branch_branch_id_seq'::regclass);


--
-- Name: category category_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.category ALTER COLUMN category_id SET DEFAULT nextval('public.category_category_id_seq'::regclass);


--
-- Name: item item_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item ALTER COLUMN item_id SET DEFAULT nextval('public.item_item_id_seq'::regclass);


--
-- Name: item_alias alias_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_alias ALTER COLUMN alias_id SET DEFAULT nextval('public.item_alias_alias_id_seq'::regclass);


--
-- Name: stock_movement movement_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movement ALTER COLUMN movement_id SET DEFAULT nextval('public.stock_movement_movement_id_seq'::regclass);


--
-- Name: stocktake stocktake_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocktake ALTER COLUMN stocktake_id SET DEFAULT nextval('public.stocktake_stocktake_id_seq'::regclass);


--
-- Data for Name: branch; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.branch (branch_id, code, name, is_real) FROM stdin;
1	3MARIAS	3 Marías	t
2	TELEFERICO	Teleférico Rojo	t
3	SIN_ASIGNAR	Sin asignar	f
\.


--
-- Data for Name: category; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.category (category_id, name) FROM stdin;
1	212-15d5
2	Aceite
3	Alógeno
4	Amortiguador
5	Amortiguadordelantero
6	Anticongelante
7	Aro
8	Aspa
9	Bicel
10	Bisel
11	Brazo
12	Buchera
13	Caliper
14	Candado
15	Cantonera
16	Capota
17	Capuchón
18	Chisguete
19	Cola
20	Consola
21	Cruceta
22	Disco
23	Ecu
24	Elsejo
25	Embellecedor
26	Espejo
27	Estabilizador
28	Estuche
29	Farol
30	Filtro
31	Foco
32	Frontal
33	Grasa
34	Guardabarro
35	Guardafango
36	Guiñador
37	Jalador
38	Jeep
39	Junta
40	Llanta
41	Luz
42	Maletera
43	Masacara
44	Mataburro
45	Media
46	Miedia
47	MuñonES
48	Muñón
49	Máscara
50	Parachoque
51	Pastilla
52	Perno
53	Pisadera
54	Porta
55	Prensa
56	Puerta
57	Radiador
58	Reflector
59	Retrovisor
60	Rodamiento
61	Rótula
62	Scooter
63	Set
64	Stop
65	Stop-LANCER
66	Suzuki
67	Tacometro
68	Tapa
69	Tapabarro
70	Toma
71	Toyota
72	Turbo
73	Varios
74	Velocimetro
\.


--
-- Data for Name: item; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.item (item_id, sku, part_code, base_code, side, category_id, description, unit_price, legacy_row_id, needs_review, is_active, created_at) FROM stdin;
1	DEPO-00001	2644-R	2644	R	1	212-15D5 DE HICE	\N	512	f	t	2026-07-24 14:19:44.077972+00
2	DEPO-00002	SAE-40	SAE-40	\N	2	Aceite PARA MOTOR	20.00	1182	f	t	2026-07-24 14:19:44.077972+00
3	DEPO-00003	210-0202-002-L	210-0202-002	L	3	Alogeno BONGO	200.00	146	f	t	2026-07-24 14:19:44.077972+00
4	DEPO-00004	210-0202-002-R	210-0202-002	R	3	Alogeno BONGO	200.00	147	f	t	2026-07-24 14:19:44.077972+00
5	DEPO-00005	846-L	846	L	3	Alogeno JUNIOR	200.00	148	f	t	2026-07-24 14:19:44.077972+00
6	DEPO-00006	846-R	846	R	3	Alogeno JUNIOR	200.00	149	f	t	2026-07-24 14:19:44.077972+00
7	DEPO-00007	13-42-L	13-42	L	3	Alogeno LEVIN 97	250.00	1200	f	t	2026-07-24 14:19:44.077972+00
8	DEPO-00008	13-42-R	13-42	R	3	Alogeno LEVIN 97	250.00	1201	f	t	2026-07-24 14:19:44.077972+00
9	DEPO-00009	19027-L	19027	L	3	Alogeno SUZUKI VITARA	200.00	158	f	t	2026-07-24 14:19:44.077972+00
10	DEPO-00010	19027-R	19027	R	3	Alogeno SUZUKI VITARA	200.00	159	f	t	2026-07-24 14:19:44.077972+00
11	DEPO-00011	400-L	400	L	3	Alogeno SWIFT	150.00	156	f	t	2026-07-24 14:19:44.077972+00
12	DEPO-00012	400-R	400	R	3	Alogeno SWIFT	150.00	157	f	t	2026-07-24 14:19:44.077972+00
13	DEPO-00013	A-VAR	A-VAR	\N	3	Alogeno VARIOS	1.00	1010	f	t	2026-07-24 14:19:44.077972+00
14	DEPO-00014	114-20257-TW-R	114-20257-TW	R	3	Alogeno FORESTER	160.00	155	f	t	2026-07-24 14:19:44.077972+00
15	DEPO-00015	20597-C	20597-C	\N	3	Alogeno FORESTER	190.00	150	f	t	2026-07-24 14:19:44.077972+00
16	DEPO-00016	20597-Y	20597-Y	\N	3	Alogeno FORESTER AMARILLO	700.00	152	f	t	2026-07-24 14:19:44.077972+00
17	DEPO-00017	870118-G	870118-G	\N	4	Amortiguador IPSUM 2004 TRASERO	125.00	145	f	t	2026-07-24 14:19:44.077972+00
18	DEPO-00018	121118	121118	\N	4	Amortiguador TOYOTA STARLET	142.50	1181	f	t	2026-07-24 14:19:44.077972+00
19	DEPO-00019	87017	87017	\N	4	Amortiguador CARRY TRASERO	142.50	1171	f	t	2026-07-24 14:19:44.077972+00
20	DEPO-00020	870014	870014	\N	4	Amortiguador COROLLA TRASERO L	155.00	28	f	t	2026-07-24 14:19:44.077972+00
21	DEPO-00021	870025-G	870025-G	\N	4	Amortiguador DE CALDINA RTRASERO A MUELLE	68.00	142	f	t	2026-07-24 14:19:44.077972+00
22	DEPO-00022	870106-G	870106-G	\N	4	Amortiguador DE CARRY	150.00	36	f	t	2026-07-24 14:19:44.077972+00
23	DEPO-00023	87009-O	87009-O	\N	4	Amortiguador DE COROLLA TRASERO 90 º	63.00	144	f	t	2026-07-24 14:19:44.077972+00
24	DEPO-00024	870077-G	870077-G	\N	4	Amortiguador DE PATHINDER TERRANO TRASERO 56210-0W001	75.00	1135	f	t	2026-07-24 14:19:44.077972+00
25	DEPO-00025	AP-P	AP-P	\N	4	Amortiguador DE Puerta PARES	100.00	161	f	t	2026-07-24 14:19:44.077972+00
26	DEPO-00026	AP-S	AP-S	\N	4	Amortiguador DE Puerta SUELTOS	50.00	162	f	t	2026-07-24 14:19:44.077972+00
27	DEPO-00027	870089	870089	\N	4	Amortiguador DELANTERO APV	142.50	1186	f	t	2026-07-24 14:19:44.077972+00
28	DEPO-00028	DS-2007	DS-2007	\N	4	Amortiguador DELANTERO HILUX 90	125.00	1172	f	t	2026-07-24 14:19:44.077972+00
29	DEPO-00029	870059-G	870059-G	\N	4	Amortiguador DELANTERO L	130.00	30	f	t	2026-07-24 14:19:44.077972+00
30	DEPO-00030	870028	870028	\N	4	Amortiguador DELANTERO LEVIN TRUENO L	142.50	1178	f	t	2026-07-24 14:19:44.077972+00
31	DEPO-00031	870027	870027	\N	4	Amortiguador DELANTERO LEVIN TRUENO R	142.50	1179	f	t	2026-07-24 14:19:44.077972+00
32	DEPO-00032	870044	870044	\N	4	Amortiguador DELANTERO PROBOX (L)	135.00	29	f	t	2026-07-24 14:19:44.077972+00
33	DEPO-00033	870047-G	870047-G	\N	4	Amortiguador Delantero R-L NOAH LITEACE 97-02 GAS	72.00	1144	f	t	2026-07-24 14:19:44.077972+00
34	DEPO-00034	870105-G	870105-G	\N	4	Amortiguador DELNTERO CARRY	23.00	35	f	t	2026-07-24 14:19:44.077972+00
35	DEPO-00035	870021-G	870021-G	\N	4	Amortiguador HIACE	34.50	141	f	t	2026-07-24 14:19:44.077972+00
36	DEPO-00036	341372	341372	\N	4	Amortiguador HIALUX VIGO DELANTERO SHIBUMI	230.00	1134	f	t	2026-07-24 14:19:44.077972+00
37	DEPO-00037	870065-G	870065-G	\N	4	Amortiguador HONDA EG TRASERO	130.00	33	f	t	2026-07-24 14:19:44.077972+00
38	DEPO-00038	870100-G	870100-G	\N	4	Amortiguador IPSUM MODERNO DELANTERO	68.00	34	f	t	2026-07-24 14:19:44.077972+00
39	DEPO-00039	2618	2618	\N	4	Amortiguador IZUSU TROPER DELANTERO SHIBUMI	63.00	1136	f	t	2026-07-24 14:19:44.077972+00
40	DEPO-00040	870026-G	870026-G	\N	4	Amortiguador LAND CRUISER	65.50	1130	f	t	2026-07-24 14:19:44.077972+00
41	DEPO-00041	870063-G	870063-G	\N	4	Amortiguador MONTERO DELANTERO 02	130.00	32	f	t	2026-07-24 14:19:44.077972+00
42	DEPO-00042	870051-G	870051-G	\N	4	Amortiguador MONTERO TRASER 98	65.50	1169	f	t	2026-07-24 14:19:44.077972+00
43	DEPO-00043	870051-O	870051-O	\N	4	Amortiguador MONTERO TRASER 98	65.50	1146	f	t	2026-07-24 14:19:44.077972+00
44	DEPO-00044	870045	870045	\N	4	Amortiguador PROBOX 4WD 1NZ 4X4 RH	42.50	1014	f	t	2026-07-24 14:19:44.077972+00
45	DEPO-00045	870058-G	870058-G	\N	4	Amortiguador PROBOX NOAH TRASERO	72.00	1137	f	t	2026-07-24 14:19:44.077972+00
46	DEPO-00046	870068-G	870068-G	\N	4	Amortiguador RAV4 DELANTERO	168.00	1180	f	t	2026-07-24 14:19:44.077972+00
47	DEPO-00047	870122	870122	\N	4	Amortiguador SUZUKI ALTO	34.00	38	f	t	2026-07-24 14:19:44.077972+00
48	DEPO-00048	A-2159	A-2159	\N	4	Amortiguador SUZUKI SWIFT L	168.00	1142	f	t	2026-07-24 14:19:44.077972+00
49	DEPO-00049	A-2158	A-2158	\N	4	Amortiguador SUZUKI SWIFT R	168.00	1141	f	t	2026-07-24 14:19:44.077972+00
50	DEPO-00050	870060-G	870060-G	\N	4	Amortiguador SUZUKI VITRA R	130.00	31	f	t	2026-07-24 14:19:44.077972+00
51	DEPO-00051	870047-O	870047-O	\N	4	Amortiguador TOWN ACE NOAH DELANTERO	65.50	1143	f	t	2026-07-24 14:19:44.077972+00
52	DEPO-00052	870086-G	870086-G	\N	4	Amortiguador TOYOTA DELANTERO HIACE	68.00	143	f	t	2026-07-24 14:19:44.077972+00
53	DEPO-00053	870033-G	870033-G	\N	4	Amortiguador TRASERO CALDINA ESPIRAL (L)	142.50	1188	f	t	2026-07-24 14:19:44.077972+00
54	DEPO-00054	870009-G	870009-G	\N	4	Amortiguador TRASERO DE COROLLA A GAS	68.00	140	f	t	2026-07-24 14:19:44.077972+00
55	DEPO-00055	870103-G	870103-G	\N	4	Amortiguador TRASERO MITSUBISHI CHARIOT RVR	125.00	1187	f	t	2026-07-24 14:19:44.077972+00
56	DEPO-00056	120079	120079	\N	4	Amortiguador TRASERO STARLET EP82	50.00	2	f	t	2026-07-24 14:19:44.077972+00
57	DEPO-00057	870013-G	870013-G	\N	4	Amortiguador Trasero TOY COROLLA RH AE101-CE100 GAS YOITOKI	142.50	1013	f	t	2026-07-24 14:19:44.077972+00
58	DEPO-00058	870007-G	870007-G	\N	4	Amortiguador Trasero TOY DIESEL/GASOLINA COR/VAG TOKICO GAS	65.50	1147	f	t	2026-07-24 14:19:44.077972+00
59	DEPO-00059	870007-O	870007-O	\N	4	Amortiguador Trasero TOY DIESEL/GASOLINA COR/VAG TOKICO OIL	65.50	1170	f	t	2026-07-24 14:19:44.077972+00
60	DEPO-00060	810100-G	810100-G	\N	4	Amortiguador URVAN CHANCHO E25 DELANTERO	65.50	1173	f	t	2026-07-24 14:19:44.077972+00
61	DEPO-00061	870008-G	870008-G	\N	4	Amortiguador HIACE TRSERO	59.50	139	f	t	2026-07-24 14:19:44.077972+00
62	DEPO-00062	870096-G	870096-G	\N	4	Amortiguador TRASERO HIACE 2001-2005 OREJA GRANDE	145.00	1145	f	t	2026-07-24 14:19:44.077972+00
63	DEPO-00063	SK-A	SK-A	\N	6	Anticongelante SUPER KOTE COLOR AMARILLO	75.00	1192	f	t	2026-07-24 14:19:44.077972+00
64	DEPO-00064	SK-V	SK-V	\N	6	Anticongelante SUPER KOTE COLOR VERDE	46.00	1191	f	t	2026-07-24 14:19:44.077972+00
65	DEPO-00065	16X7JJ-5	16X7JJ-5	\N	7	Aro SUBARU DORADO	300.00	1009	f	t	2026-07-24 14:19:44.077972+00
66	DEPO-00066	GPC-1001	GPC-1001	\N	8	Aspa IPSUM 96~97~98~99~2000 VENTILADOR COMPLETO 36,5cmX35,4cm	160.00	942	f	t	2026-07-24 14:19:44.077972+00
67	DEPO-00067	53131-13020-R	53131-13020	R	10	Bisel COROLLA 90	1.00	961	f	t	2026-07-24 14:19:44.077972+00
68	DEPO-00068	13-31-R	13-31	R	10	Bisel COROLLA KE70 84 212-1231	20.00	1049	f	t	2026-07-24 14:19:44.077972+00
69	DEPO-00069	13-28-R	13-28	R	10	Bisel COROLLA KE70 84 CON FRANJA BLANCA 212-1227	20.00	1048	f	t	2026-07-24 14:19:44.077972+00
70	DEPO-00070	BF-CALDINA-L	BF-CALDINA	L	10	Bisel DE Farol CALDINA GT	1.00	975	f	t	2026-07-24 14:19:44.077972+00
71	DEPO-00071	BF-CALDINA-R	BF-CALDINA	R	10	Bisel DE Farol CALDINA GT	1.00	976	f	t	2026-07-24 14:19:44.077972+00
72	DEPO-00072	BM-JUNIOR	BM-JUNIOR	\N	10	Bisel DE Mascara JUNIOR	1.00	974	f	t	2026-07-24 14:19:44.077972+00
73	DEPO-00073	BS-IMPREZA-L	BS-IMPREZA	L	10	Bisel DE Stop SUBARU IMPREZA	1.00	972	f	t	2026-07-24 14:19:44.077972+00
74	DEPO-00074	BS-IMPREZA-R	BS-IMPREZA	R	10	Bisel DE Stop SUBARU IMPREZA	1.00	973	f	t	2026-07-24 14:19:44.077972+00
75	DEPO-00075	53130-95J05-R	53130-95J05	R	10	Bisel HIACE Mod,85~88 Foco CUADRADO 212-1221	25.00	1051	f	t	2026-07-24 14:19:44.077972+00
76	DEPO-00076	74081-EX0100-L	74081-EX0100	L	10	Bisel SUNNY 310	1.00	1050	f	t	2026-07-24 14:19:44.077972+00
77	DEPO-00077	860033	860033	\N	11	Brazo de cremallera HIDRAULICO IPSUM (Hilo fino x 1.5 ext.)16X14X1,5	33.00	11	f	t	2026-07-24 14:19:44.077972+00
78	DEPO-00078	860030	860030	\N	11	Brazo de cremallera HIDRAULICO YOITOKI UNIVERSAL 14X16	25.00	10	f	t	2026-07-24 14:19:44.077972+00
79	DEPO-00079	860029	860029	\N	11	Brazo de cremallera TOYOTA LARGO YOITOKI Mecanico 14X14	36.00	9	f	t	2026-07-24 14:19:44.077972+00
80	DEPO-00080	860096	860096	\N	11	Brazo de cremallera TOYOTA/NISSAN LARGO YOITOKI Mecanico 14X15	26.00	1138	f	t	2026-07-24 14:19:44.077972+00
81	DEPO-00081	BU-SURF-F-R	BU-SURF-F	R	12	Buchera HILUX SURF 96 FIBRA	35.00	164	f	t	2026-07-24 14:19:44.077972+00
82	DEPO-00082	CALIPER-VAR	CALIPER-VAR	\N	13	Caliper STI MORDAZA	350.00	900	f	t	2026-07-24 14:19:44.077972+00
83	DEPO-00083	GF-DOMINGO-L	GF-DOMINGO	L	15	Cantonera METALICA DE SUBARU DOMINGO	70.00	174	f	t	2026-07-24 14:19:44.077972+00
84	DEPO-00084	GF-DOMINGO-R	GF-DOMINGO	R	15	Cantonera METALICA DE SUBARU DOMINGO	70.00	175	f	t	2026-07-24 14:19:44.077972+00
85	DEPO-00085	C-FORESTER-97	C-FORESTER-97	\N	16	Capota FORESTER 97	1.00	170	f	t	2026-07-24 14:19:44.077972+00
86	DEPO-00086	C-CIVIC-92	C-CIVIC-92	\N	16	Capota HONDA CIVIC EG	300.00	169	f	t	2026-07-24 14:19:44.077972+00
87	DEPO-00087	C-EVO4	C-EVO4	\N	16	Capota MITSUBISHI EVOLUTION 4	1000.00	171	f	t	2026-07-24 14:19:44.077972+00
88	DEPO-00088	C-CULTUS-91	C-CULTUS-91	\N	16	Capota SUZUKI CULTUS	300.00	176	f	t	2026-07-24 14:19:44.077972+00
89	DEPO-00089	C-VITARA-97	C-VITARA-97	\N	16	Capota SUZUKI VITARA 97 ESCUDO	700.00	177	f	t	2026-07-24 14:19:44.077972+00
90	DEPO-00090	C-SURF-96	C-SURF-96	\N	16	Capota TOYOTA HILUX SURF	700.00	178	f	t	2026-07-24 14:19:44.077972+00
91	DEPO-00091	CAT-300	CAT-300	\N	17	Capuchón CON TOPE DE Amortiguador	11.00	1084	f	t	2026-07-24 14:19:44.077972+00
92	DEPO-00092	400402	400402	\N	17	Capuchón de cremallera HIDRAULICO CORTO MAMUT	9.00	1086	f	t	2026-07-24 14:19:44.077972+00
93	DEPO-00093	400001	400001	\N	17	Capuchón de JUNTA CE90/AE90 MAMUT	9.00	1129	f	t	2026-07-24 14:19:44.077972+00
94	DEPO-00094	400002	400002	\N	17	Capuchón de JUNTA CE90/AE90 MAMUT	7.00	1085	f	t	2026-07-24 14:19:44.077972+00
95	DEPO-00095	400200	400200	\N	17	Capuchón de TRICETA Toyota AE90~CE90 MAMUT	9.00	1087	f	t	2026-07-24 14:19:44.077972+00
96	DEPO-00096	CHI-P-M	CHI-P-M	\N	18	Chisguete DE PARCHOQUE MONTERO	25.00	565	f	t	2026-07-24 14:19:44.077972+00
97	DEPO-00097	CP-RAV4-F	CP-RAV4-F	\N	19	Cola DE PATO RAV 4 98 FIBRA	150.00	1081	f	t	2026-07-24 14:19:44.077972+00
98	DEPO-00098	CP-RAV4	CP-RAV4	\N	19	Cola DE PATO RAV 4 98 ORIGINAL	300.00	1081	f	t	2026-07-24 14:19:44.077972+00
99	DEPO-00099	CP-FORESTER00-F	CP-FORESTER00-F	\N	19	Cola DE PATO SUBARU FORESTER 2000 Fibra vidrio	150.00	1082	f	t	2026-07-24 14:19:44.077972+00
100	DEPO-00100	CP-FORESTER97	CP-FORESTER97	\N	19	Cola DE PATO SUBARU FORESTER 97	50.00	1082	f	t	2026-07-24 14:19:44.077972+00
101	DEPO-00101	CON-VAR	CON-VAR	\N	20	Consola CENTRAL	50.00	902	f	t	2026-07-24 14:19:44.077972+00
102	DEPO-00102	CON-R-VAR	CON-R-VAR	\N	20	Consola de Radio CARIB Café	66.00	1199	f	t	2026-07-24 14:19:44.077972+00
103	DEPO-00103	212-1592-L	212-1592	L	45	Media luz COROLLA Mod. 95 ~ 96 AE110. SAPITO	20.00	47	f	t	2026-07-24 14:19:44.077972+00
104	DEPO-00104	121222	121222	\N	21	Cruceta de dirección Completa TOYOTA AE 90 ( CARDAN ) YOI-273	40.00	1132	f	t	2026-07-24 14:19:44.077972+00
105	DEPO-00105	121219	121219	\N	21	Cruceta de dirección Completa TOYOTA TURING HIDRAULICO CORTO YOI-265	40.00	1133	f	t	2026-07-24 14:19:44.077972+00
106	DEPO-00106	121221	121221	\N	21	Cruceta de dirección Completa YOI-272 UNIVERSAL	40.00	1131	f	t	2026-07-24 14:19:44.077972+00
107	DEPO-00107	FJD005U	FJD005U	\N	22	Disco Subaru DOMINGO	261.00	1205	f	t	2026-07-24 14:19:44.077972+00
108	DEPO-00108	CPU-1F	CPU-1F	\N	23	ECU SUBARU	700.00	908	f	t	2026-07-24 14:19:44.077972+00
109	DEPO-00109	CPU-4W	CPU-4W	\N	23	ECU SUBARU	700.00	907	f	t	2026-07-24 14:19:44.077972+00
110	DEPO-00110	CPU-3S-G	CPU-3S-G	\N	23	ECU TOYOTA 3SG	400.00	897	f	t	2026-07-24 14:19:44.077972+00
111	DEPO-00111	21-32-R	21-32	R	25	Embellecedor CALDINA TURING	150.00	332	f	t	2026-07-24 14:19:44.077972+00
112	DEPO-00112	1149-204-L	1149-204	L	25	Embellecedor MITSUBISHI EVOLUCION LANCER1,2,3	200.00	614	f	t	2026-07-24 14:19:44.077972+00
113	DEPO-00113	1149-204-R	1149-204	R	25	Embellecedor MITSUBISHI EVOLUCION LANCER 1,2,3	200.00	615	f	t	2026-07-24 14:19:44.077972+00
114	DEPO-00114	2143-L	2143	L	25	Embellecedor CALDINA GT	\N	1110	f	t	2026-07-24 14:19:44.077972+00
115	DEPO-00115	2143-R	2143	R	25	Embellecedor CALDINA GT	50.00	1111	f	t	2026-07-24 14:19:44.077972+00
116	DEPO-00116	20-207-L	20-207	L	25	Embellecedor CORONA 88-89	70.00	1019	f	t	2026-07-24 14:19:44.077972+00
117	DEPO-00117	20-207-R	20-207	R	25	Embellecedor CORONA 88-89	70.00	1020	f	t	2026-07-24 14:19:44.077972+00
118	DEPO-00118	EM-FORESTER-F	EM-FORESTER-F	\N	25	Embellecedor FORESTER FIBRA	75.00	1080	f	t	2026-07-24 14:19:44.077972+00
119	DEPO-00119	11216-R	11216	R	26	Espejo HONDA EG ELECTRICO 3 PINES	45.00	196	f	t	2026-07-24 14:19:44.077972+00
120	DEPO-00120	010467-L	010467	L	26	Espejo ATRAIL CROMADO	100.00	186	f	t	2026-07-24 14:19:44.077972+00
121	DEPO-00121	010467-R	010467	R	26	Espejo ATRAIL CROMADO	100.00	187	f	t	2026-07-24 14:19:44.077972+00
122	DEPO-00122	547139-L	547139	L	26	Espejo CAMRY	75.00	271	f	t	2026-07-24 14:19:44.077972+00
123	DEPO-00123	2960-L	2960	L	26	Espejo CHAPULIN HUEVO	75.00	181	f	t	2026-07-24 14:19:44.077972+00
124	DEPO-00124	2960-R	2960	R	26	Espejo CHAPULIN HUEVO	75.00	182	f	t	2026-07-24 14:19:44.077972+00
125	DEPO-00125	3719-L	3719	L	26	Espejo CHARIOT RVR	100.00	216	f	t	2026-07-24 14:19:44.077972+00
126	DEPO-00126	2277-L	2277	L	26	Espejo COROLLA 92 ELECTRICO 3 PINES	100.00	274	f	t	2026-07-24 14:19:44.077972+00
127	DEPO-00127	222111-R	222111	R	26	Espejo COROLLA 92 NEGRO R/L Retrovisor MAMUT Unidad CARIB SPRINTER	75.00	1122	f	t	2026-07-24 14:19:44.077972+00
128	DEPO-00128	010466-L	010466	L	26	Espejo DATAUN ATRAIL NEGRO	75.00	188	f	t	2026-07-24 14:19:44.077972+00
129	DEPO-00129	E-PT-VAR	E-PT-VAR	\N	26	Espejo DE MALETERO UNIVERSAL VARIOS CON BRAZO	70.00	204	f	t	2026-07-24 14:19:44.077972+00
130	DEPO-00130	3366-R	3366	R	26	Espejo HIACE 96	100.00	957	f	t	2026-07-24 14:19:44.077972+00
131	DEPO-00131	3367-L	3367	L	26	Espejo HIACE 96 LOBO CHINO	100.00	983	f	t	2026-07-24 14:19:44.077972+00
132	DEPO-00132	E-HONDA-VAR	E-HONDA-VAR	\N	26	Espejo HONDA VARIOS	75.00	202	f	t	2026-07-24 14:19:44.077972+00
133	DEPO-00133	2787-L	2787	L	26	Espejo HONDA ACCORD 96 ELECTRICO	70.00	977	f	t	2026-07-24 14:19:44.077972+00
134	DEPO-00134	2787-R	2787	R	26	Espejo HONDA ACCORD 96 ELECTRICO	70.00	978	f	t	2026-07-24 14:19:44.077972+00
135	DEPO-00135	19050-R	19050	R	26	Espejo HONDA ACCORD ELECTRICO	75.00	191	f	t	2026-07-24 14:19:44.077972+00
136	DEPO-00136	011003-L	011003	L	26	Espejo HONDA EG ELEVTRICO	70.00	192	f	t	2026-07-24 14:19:44.077972+00
137	DEPO-00137	011003-R	011003	R	26	Espejo HONDA EG ELEVTRICO 7 PINES	70.00	193	f	t	2026-07-24 14:19:44.077972+00
138	DEPO-00138	11003-L	11003	L	26	Espejo HONDA EG MANUAL	70.00	194	f	t	2026-07-24 14:19:44.077972+00
139	DEPO-00139	11003-R	11003	R	26	Espejo HONDA EG MANUAL	70.00	195	f	t	2026-07-24 14:19:44.077972+00
140	DEPO-00140	5259-L	5259	L	26	Espejo HONDA EK 95 /2 PuertaS ELECTRICO 3 PINES	70.00	197	f	t	2026-07-24 14:19:44.077972+00
141	DEPO-00141	547483-L	547483	L	26	Espejo LEVIN AE101	70.00	968	f	t	2026-07-24 14:19:44.077972+00
142	DEPO-00142	547483-R	547483	R	26	Espejo LEVIN AE101	70.00	969	f	t	2026-07-24 14:19:44.077972+00
143	DEPO-00143	4219-E3-R	4219-E3	R	26	Espejo TOYOTA SPRINTER ELECTRICO 3 PINES	70.00	276	f	t	2026-07-24 14:19:44.077972+00
144	DEPO-00144	4219-R	4219	R	26	Espejo TOYOTA SPRINTER MANUAL	75.00	277	f	t	2026-07-24 14:19:44.077972+00
145	DEPO-00145	3686-L	3686	L	26	Espejo MISTUBISHI MONTERO NEGRO	100.00	213	f	t	2026-07-24 14:19:44.077972+00
146	DEPO-00146	3686-R	3686	R	26	Espejo MISTUBISHI MONTERO NEGRO	100.00	214	f	t	2026-07-24 14:19:44.077972+00
147	DEPO-00147	MR155318-R	MR155318	R	26	Espejo MITSIBISHI JUNIOR	70.00	221	f	t	2026-07-24 14:19:44.077972+00
148	DEPO-00148	2105-L	2105	L	26	Espejo MITSUBISH GRANDDIS CROMADO	135.00	217	f	t	2026-07-24 14:19:44.077972+00
149	DEPO-00149	2105-R	2105	R	26	Espejo MITSUBISH GRANDDIS CROMADO	135.00	218	f	t	2026-07-24 14:19:44.077972+00
150	DEPO-00150	K317-R	K317	R	26	Espejo MITSUBISHI EVO 9	70.00	207	f	t	2026-07-24 14:19:44.077972+00
151	DEPO-00151	010131-R	010131	R	26	Espejo MITSUBISHI IO	70.00	208	f	t	2026-07-24 14:19:44.077972+00
152	DEPO-00152	02-0067-L	02-0067	L	26	Espejo MITSUBISHI LANCER 92	70.00	209	f	t	2026-07-24 14:19:44.077972+00
153	DEPO-00153	02-0067-R	02-0067	R	26	Espejo MITSUBISHI LANCER 92	70.00	210	f	t	2026-07-24 14:19:44.077972+00
154	DEPO-00154	5419-R	5419	R	26	Espejo MITSUBISHI LANCER 99	70.00	220	t	t	2026-07-24 14:19:44.077972+00
155	DEPO-00155	3686-C-L	3686-C	L	26	Espejo MITSUBISHI MONTERO CROMADO ELECTRICO YT7230	200.00	211	f	t	2026-07-24 14:19:44.077972+00
156	DEPO-00156	3686-C-R	3686-C	R	26	Espejo MITSUBISHI MONTERO CROMADO ELECTRICO YT7230	200.00	212	f	t	2026-07-24 14:19:44.077972+00
157	DEPO-00157	0455-N-L	0455-N	L	26	Espejo NISSAN AD 2002-2006 BY11 NEGRO 215-15A3	70.00	222	f	t	2026-07-24 14:19:44.077972+00
158	DEPO-00158	0455-N-R	0455-N	R	26	Espejo NISSAN AD 2002-2006 BY11 NEGRO 215-15A3	70.00	223	f	t	2026-07-24 14:19:44.077972+00
159	DEPO-00159	3254-L	3254	L	26	Espejo NISSAN AVENIR	70.00	227	t	t	2026-07-24 14:19:44.077972+00
160	DEPO-00160	3254-R	3254	R	26	Espejo NISSAN AVENIR	70.00	228	t	t	2026-07-24 14:19:44.077972+00
161	DEPO-00161	4675-E-L	4675-E	L	26	Espejo NISSAN B14 ELECTRICO	70.00	229	t	t	2026-07-24 14:19:44.077972+00
162	DEPO-00162	4675-E-R	4675-E	R	26	Espejo NISSAN B14 ELECTRICO	70.00	230	t	t	2026-07-24 14:19:44.077972+00
163	DEPO-00163	4675-L	4675	L	26	Espejo NISSAN B14 MANUAL	70.00	231	f	t	2026-07-24 14:19:44.077972+00
164	DEPO-00164	4675-R	4675	R	26	Espejo NISSAN B14 MANUAL	70.00	232	f	t	2026-07-24 14:19:44.077972+00
165	DEPO-00165	847P-R	847P	R	26	Espejo NISSAN BONGO	70.00	238	f	t	2026-07-24 14:19:44.077972+00
166	DEPO-00166	N36-L	N36	L	26	Espejo NISSAN CHAPULIN	70.00	224	f	t	2026-07-24 14:19:44.077972+00
167	DEPO-00167	3965-L	3965	L	26	Espejo NISSAN CUSTOM	100.00	240	f	t	2026-07-24 14:19:44.077972+00
168	DEPO-00168	8289-L	8289	L	26	Espejo NISSAN MARCH 2004	70.00	244	f	t	2026-07-24 14:19:44.077972+00
169	DEPO-00169	8289-R	8289	R	26	Espejo NISSAN MARCH 2004	70.00	246	f	t	2026-07-24 14:19:44.077972+00
170	DEPO-00170	0815-L	0815	L	26	Espejo NISSAN MARCH 87 / SKYLINE R32 /MICRA K10	70.00	250	t	t	2026-07-24 14:19:44.077972+00
171	DEPO-00171	6067-R	6067	R	26	Espejo NISSAN MARCH K11 ELECTRICO	70.00	249	f	t	2026-07-24 14:19:44.077972+00
172	DEPO-00172	3981-R	3981	R	26	Espejo NISSAN MARCH K11 MANUAL	70.00	248	f	t	2026-07-24 14:19:44.077972+00
173	DEPO-00173	3530-L	3530	L	26	Espejo NISSAN PRESSEA 97	70.00	251	f	t	2026-07-24 14:19:44.077972+00
174	DEPO-00174	0043-L	0043	L	26	Espejo NISSAN PULSAR 95 /BLUBIRD	70.00	252	f	t	2026-07-24 14:19:44.077972+00
175	DEPO-00175	0043-R	0043	R	26	Espejo NISSAN PULSAR 95 /BLUBIRD	70.00	253	f	t	2026-07-24 14:19:44.077972+00
176	DEPO-00176	3803-R	3803	R	26	Espejo NISSAN SERENA	70.00	255	f	t	2026-07-24 14:19:44.077972+00
177	DEPO-00177	4572-L	4572	L	26	Espejo NISSAN SKYLINE R33	70.00	259	f	t	2026-07-24 14:19:44.077972+00
178	DEPO-00178	4572-R	4572	R	26	Espejo NISSAN SKYLINE R33	70.00	260	f	t	2026-07-24 14:19:44.077972+00
179	DEPO-00179	192-L	192	L	26	Espejo NISSAN URBAN E23	70.00	984	f	t	2026-07-24 14:19:44.077972+00
180	DEPO-00180	7426-L	7426	L	26	Espejo PROBOX 98 BASE GRANDE	200.00	966	f	t	2026-07-24 14:19:44.077972+00
181	DEPO-00181	7426-R	7426	R	26	Espejo PROBOX 98 BASE GRANDE	200.00	967	f	t	2026-07-24 14:19:44.077972+00
182	DEPO-00182	4856-L	4856	L	26	Espejo RAV4 96	150.00	979	f	t	2026-07-24 14:19:44.077972+00
183	DEPO-00183	4856-R	4856	R	26	Espejo RAV4 96	150.00	980	f	t	2026-07-24 14:19:44.077972+00
184	DEPO-00184	122472-U	122472-U	\N	26	Espejo REDONDO UNIVERSAL PEQUEÑO	25.00	262	f	t	2026-07-24 14:19:44.077972+00
185	DEPO-00185	8030-L	8030	L	26	Espejo RESTROVISOR TOYOTA HIACE 2008 BRAZO	100.00	630	f	t	2026-07-24 14:19:44.077972+00
186	DEPO-00186	5277-R	5277	R	26	Espejo RETROVISOR HILUX SURF 99	200.00	189	f	t	2026-07-24 14:19:44.077972+00
187	DEPO-00187	3666-L	3666	L	26	Espejo RETROVISOR NISSAN AD 90	70.00	225	f	t	2026-07-24 14:19:44.077972+00
188	DEPO-00188	3666-R	3666	R	26	Espejo RETROVISOR NISSAN AD 90	70.00	226	f	t	2026-07-24 14:19:44.077972+00
189	DEPO-00189	5048-R	5048	R	26	Espejo SUBARU DOMINGO	100.00	1109	f	t	2026-07-24 14:19:44.077972+00
190	DEPO-00190	5092-L	5092	L	26	Espejo SUBARU IMPREZA 2000	75.00	263	f	t	2026-07-24 14:19:44.077972+00
191	DEPO-00191	5092-R	5092	R	26	Espejo SUBARU IMPREZA 2001	70.00	264	f	t	2026-07-24 14:19:44.077972+00
192	DEPO-00192	1644-R	1644	R	26	Espejo TOWN ACE MOD 87 212-1568	70.00	982	f	t	2026-07-24 14:19:44.077972+00
193	DEPO-00193	3095-L	3095	L	26	Espejo TOWN ACE MOD 87 212-1568	70.00	981	f	t	2026-07-24 14:19:44.077972+00
194	DEPO-00194	8112-L	8112	L	26	Espejo TOYOTA CAMRY 1992	70.00	269	t	t	2026-07-24 14:19:44.077972+00
195	DEPO-00195	8112-R	8112	R	26	Espejo TOYOTA CAMRY 1992	70.00	270	t	t	2026-07-24 14:19:44.077972+00
196	DEPO-00196	6219-L	6219	L	26	Espejo TOYOTA CAMRY 88	70.00	267	f	t	2026-07-24 14:19:44.077972+00
197	DEPO-00197	6219-R	6219	R	26	Espejo TOYOTA CAMRY 88	70.00	268	f	t	2026-07-24 14:19:44.077972+00
198	DEPO-00198	E-FX	E-FX	\N	26	Espejo TOYOTA COROLLA FX	70.00	291	t	t	2026-07-24 14:19:44.077972+00
199	DEPO-00199	4766-L	4766	L	26	Espejo TOYOTA CORONA 93	70.00	278	f	t	2026-07-24 14:19:44.077972+00
200	DEPO-00200	3710-L	3710	L	26	Espejo TOYOTA CORSA 90	70.00	281	f	t	2026-07-24 14:19:44.077972+00
201	DEPO-00201	48692-L	48692	L	26	Espejo TOYOTA CORSA 96	70.00	282	f	t	2026-07-24 14:19:44.077972+00
202	DEPO-00202	4453-L	4453	L	26	Espejo TOYOTA CROWN	70.00	284	f	t	2026-07-24 14:19:44.077972+00
203	DEPO-00203	4453-R	4453	R	26	Espejo TOYOTA CROWN	70.00	285	f	t	2026-07-24 14:19:44.077972+00
204	DEPO-00204	5483-L	5483	L	26	Espejo TOYOTA IPSUM ELÉCTRICO	70.00	294	f	t	2026-07-24 14:19:44.077972+00
205	DEPO-00205	5483-R	5483	R	26	Espejo TOYOTA IPSUM ELÉCTRICO	70.00	295	f	t	2026-07-24 14:19:44.077972+00
206	DEPO-00206	5862-L	5862	L	26	Espejo TOYOTA IPSUM	70.00	292	f	t	2026-07-24 14:19:44.077972+00
207	DEPO-00207	5862-R	5862	R	26	Espejo TOYOTA IPSUM	100.00	293	f	t	2026-07-24 14:19:44.077972+00
208	DEPO-00208	561326-R	561326	R	26	Espejo TOYOTA LEVIN TRUNO 90	70.00	299	f	t	2026-07-24 14:19:44.077972+00
209	DEPO-00209	3009-L	3009	L	26	Espejo TOYOTA MARCK 98	70.00	305	f	t	2026-07-24 14:19:44.077972+00
210	DEPO-00210	3009-R	3009	R	26	Espejo TOYOTA MARCK 98	70.00	306	f	t	2026-07-24 14:19:44.077972+00
211	DEPO-00211	G-30-L	G-30	L	26	Espejo TOYOTA MARCK 98	70.00	307	f	t	2026-07-24 14:19:44.077972+00
212	DEPO-00212	G-30-R	G-30	R	26	Espejo TOYOTA MARCK 98	70.00	308	f	t	2026-07-24 14:19:44.077972+00
213	DEPO-00213	4230-L	4230	L	26	Espejo TOYOTA MARINO	70.00	303	f	t	2026-07-24 14:19:44.077972+00
214	DEPO-00214	5574-L	5574	L	26	Espejo TOYOTA RAV 4 MOD 99	100.00	311	f	t	2026-07-24 14:19:44.077972+00
215	DEPO-00215	5574-R	5574	R	26	Espejo TOYOTA RAV 4 MOD 99	100.00	312	f	t	2026-07-24 14:19:44.077972+00
216	DEPO-00216	5430-L	5430	L	26	Espejo TOYOTA REFLEX	70.00	313	f	t	2026-07-24 14:19:44.077972+00
217	DEPO-00217	5480-L	5480	L	26	Espejo TOYOTA SPACIO NEGRO ELECTRICO	200.00	317	f	t	2026-07-24 14:19:44.077972+00
218	DEPO-00218	8278-L	8278	L	26	Espejo TOYOTA VITZ ELECTRICO	70.00	321	f	t	2026-07-24 14:19:44.077972+00
219	DEPO-00219	8278-R	8278	R	26	Espejo TOYOTA VITZ ELECTRICO	70.00	324	f	t	2026-07-24 14:19:44.077972+00
220	DEPO-00220	B38-L	B38	L	26	Espejo URVAN E25 CON BRAZO	100.00	958	f	t	2026-07-24 14:19:44.077972+00
221	DEPO-00221	1621-L	1621	L	26	Espejo CRESSIDA	70.00	283	f	t	2026-07-24 14:19:44.077972+00
222	DEPO-00222	547483-E-R	547483-E	R	26	Espejo LEVIN 95 ELECTRICO	70.00	243	f	t	2026-07-24 14:19:44.077972+00
223	DEPO-00223	464-R	464	R	26	Espejo MITSUBISHI CHALLENGER	70.00	215	f	t	2026-07-24 14:19:44.077972+00
224	DEPO-00224	8222-R	8222	R	26	Espejo NISSAN BLUEBIRTH 91-95	70.00	236	f	t	2026-07-24 14:19:44.077972+00
225	DEPO-00225	5770-L	5770	L	26	Espejo TOYOTA CALDINA GT	150.00	265	f	t	2026-07-24 14:19:44.077972+00
226	DEPO-00226	5770-R	5770	R	26	Espejo TOYOTA CALDINA GT	150.00	266	f	t	2026-07-24 14:19:44.077972+00
227	DEPO-00227	3352-R	3352	R	26	Espejo TOYOTA CELICA 90	70.00	272	f	t	2026-07-24 14:19:44.077972+00
228	DEPO-00228	4696-R	4696	R	26	Espejo TOYOTA CELICA 98	70.00	273	f	t	2026-07-24 14:19:44.077972+00
229	DEPO-00229	3488-2-R	3488-2	R	26	Espejo TOYOTA COROLLA 90 MANUAL	70.00	275	f	t	2026-07-24 14:19:44.077972+00
230	DEPO-00230	6658-L	6658	L	26	Espejo TOYOTA VITZ MANUAL	70.00	322	f	t	2026-07-24 14:19:44.077972+00
231	DEPO-00231	6658-R	6658	R	26	Espejo TOYOTA VITZ MANUAL	70.00	323	f	t	2026-07-24 14:19:44.077972+00
232	DEPO-00232	P38-L	P38	L	26	Espejo CHANCHO	70.00	239	f	t	2026-07-24 14:19:44.077972+00
233	DEPO-00233	561327-L	561327	L	26	Espejo TOYOTA LEVIN 95	70.00	297	f	t	2026-07-24 14:19:44.077972+00
234	DEPO-00234	8102-L	8102	L	26	Espejo CEDRICK Y31/Y30 87/89	70.00	184	f	t	2026-07-24 14:19:44.077972+00
235	DEPO-00235	8102-R	8102	R	26	Espejo CEDRICK Y31/Y30 87/89	70.00	185	f	t	2026-07-24 14:19:44.077972+00
236	DEPO-00236	0455-L	0455	L	26	Espejo NISSAN B15 PLOMO PATA LARGA	70.00	233	f	t	2026-07-24 14:19:44.077972+00
237	DEPO-00237	0455-R	0455	R	26	Espejo NISSAN B15 PLOMO PATA LARGA	70.00	234	f	t	2026-07-24 14:19:44.077972+00
238	DEPO-00238	4439-L	4439	L	26	Espejo NISSAN LARGO 97	70.00	241	f	t	2026-07-24 14:19:44.077972+00
239	DEPO-00239	4439-R	4439	R	26	Espejo NISSAN LARGO 97	70.00	242	f	t	2026-07-24 14:19:44.077972+00
240	DEPO-00240	1739-R	1739	R	26	Espejo TOYOTA EP71	75.00	288	f	t	2026-07-24 14:19:44.077972+00
241	DEPO-00241	5589-R	5589	R	26	Espejo TOYOTA LITE ACE CR40 97/2000	75.00	300	f	t	2026-07-24 14:19:44.077972+00
242	DEPO-00242	3369-L	3369	L	26	Espejo TOYOTA LOBO YT7013 ELECTRICO	100.00	301	f	t	2026-07-24 14:19:44.077972+00
243	DEPO-00243	3369-R	3369	R	26	Espejo TOYOTA LOBO YT7013 ELECTRICO	100.00	302	f	t	2026-07-24 14:19:44.077972+00
244	DEPO-00244	542833-R	542833	R	26	Espejo TOYOTA SUPER CRAWN	70.00	314	f	t	2026-07-24 14:19:44.077972+00
245	DEPO-00245	542834-L	542834	L	26	Espejo TOYOTA SUPER CRAWN	70.00	315	f	t	2026-07-24 14:19:44.077972+00
246	DEPO-00246	860011	860011	\N	27	Estabilizador DE IPSUM L	20.00	6	f	t	2026-07-24 14:19:44.077972+00
247	DEPO-00247	860012	860012	\N	27	Estabilizador DE IPSUM R	19.00	7	f	t	2026-07-24 14:19:44.077972+00
248	DEPO-00248	860010	860010	\N	27	Estabilizador DELANTERO DE COROOLA	25.00	5	f	t	2026-07-24 14:19:44.077972+00
249	DEPO-00249	860119	860119	\N	27	Estabilizador HILUX VIGO R	27.70	1158	f	t	2026-07-24 14:19:44.077972+00
250	DEPO-00250	860127	860127	\N	27	Estabilizador HILUX VIGO TRASERO L	27.70	1157	f	t	2026-07-24 14:19:44.077972+00
251	DEPO-00251	860100	860100	\N	27	Estabilizador RAV4 97-2004	23.00	1175	f	t	2026-07-24 14:19:44.077972+00
252	DEPO-00252	860018	860018	\N	27	Estabilizador XTRAIL UNIVERSAL	23.00	1165	f	t	2026-07-24 14:19:44.077972+00
253	DEPO-00253	EH-SUBARU	EH-SUBARU	\N	28	Estuche de HERRAMIENTA SUBARU	20.00	926	f	t	2026-07-24 14:19:44.077972+00
254	DEPO-00254	EH-TOYOTA	EH-TOYOTA	\N	28	Estuche de HERRAMIENTA TOYOTA	15.00	934	f	t	2026-07-24 14:19:44.077972+00
255	DEPO-00255	SCOOTER-MO	SCOOTER-MO	\N	28	Estuche MOCHILA SCOOTER	100.00	869	f	t	2026-07-24 14:19:44.077972+00
256	DEPO-00256	12-148-L	12-148	L	10	Bisel Y Media luz 212-1203 F-KE 1972	100.00	337	f	t	2026-07-24 14:19:44.077972+00
257	DEPO-00257	10-32247-L	10-32247	L	29	Farol -SUZUKI CULTUS 218-1106	150.00	352	f	t	2026-07-24 14:19:44.077972+00
258	DEPO-00258	F-AE86-L	F-AE86	L	29	Farol AE86	200.00	365	f	t	2026-07-24 14:19:44.077972+00
259	DEPO-00259	214-1199-L	214-1199	L	29	Farol ASX Mod. 2011~2012~2013~2014	1048.00	953	f	t	2026-07-24 14:19:44.077972+00
260	DEPO-00260	214-1199-R	214-1199	R	29	Farol ASX Mod. 2011~2012~2013~2014	1048.00	954	f	t	2026-07-24 14:19:44.077972+00
261	DEPO-00261	100-87262-L	100-87262	L	29	Farol CHARIOT GRANDIS	300.00	959	f	t	2026-07-24 14:19:44.077972+00
262	DEPO-00262	100-87262-R	100-87262	R	29	Farol CHARIOT GRANDIS	300.00	960	f	t	2026-07-24 14:19:44.077972+00
263	DEPO-00263	16-45-L	16-45	L	29	Farol COROLLA 90 CON Guiñador	25.00	963	f	t	2026-07-24 14:19:44.077972+00
264	DEPO-00264	16-45-R	16-45	R	29	Farol COROLLA 90 CON Guiñador	25.00	962	f	t	2026-07-24 14:19:44.077972+00
265	DEPO-00265	20-90-R	20-90	R	29	Farol CUADRADO UNIVERSAL CON SOPORTE	20.00	398	f	t	2026-07-24 14:19:44.077972+00
266	DEPO-00266	24522-R	24522	R	29	Farol CUADRADO UNIVERSAL CON SOPORTE	20.00	399	f	t	2026-07-24 14:19:44.077972+00
267	DEPO-00267	110-37615-L	110-37615	L	29	Farol DELICA MITSUBISHI	200.00	338	f	t	2026-07-24 14:19:44.077972+00
268	DEPO-00268	110-37615-R	110-37615	R	29	Farol DELICA MITSUBISHI	200.00	339	f	t	2026-07-24 14:19:44.077972+00
269	DEPO-00269	661-1165-L	661-1165	L	29	Farol Fiat UNO Mod.2010~2011~2012~2013~2014~2015~2016~ NEGRO	557.00	137	f	t	2026-07-24 14:19:44.077972+00
270	DEPO-00270	661-1165-R	661-1165	R	29	Farol Fiat UNO Mod.2010~2011~2012~2013~2014~2015~2016~ NEGRO	557.00	138	f	t	2026-07-24 14:19:44.077972+00
271	DEPO-00271	K30-1162-L	K30-1162	L	29	Farol FORD MUSTANG SHELBY GT500 Mod.2014~2015~2016~2017~	740.00	550	f	t	2026-07-24 14:19:44.077972+00
272	DEPO-00272	K30-1162-R	K30-1162	R	29	Farol FORD MUSTANG SHELBY GT500 Mod.2014~2015~2016~2017~	740.00	551	f	t	2026-07-24 14:19:44.077972+00
273	DEPO-00273	1550-L	1550	L	29	Farol FORESTER 97	100.00	350	f	t	2026-07-24 14:19:44.077972+00
274	DEPO-00274	100-59079-L	100-59079	L	29	Farol GRAN VITARA 218-1135	\N	354	f	t	2026-07-24 14:19:44.077972+00
275	DEPO-00275	100-59079-R	100-59079	R	29	Farol GRAN VITARA 218-1135	100.00	355	f	t	2026-07-24 14:19:44.077972+00
276	DEPO-00276	317-1180-L	317-1180	L	29	Farol HONDA CIVIC Mod. 2016~2017~2018 HATCHBACK COUPE SEDAN	1200.00	115	f	t	2026-07-24 14:19:44.077972+00
277	DEPO-00277	217-1111 PXA-L	217-1111 PXA	L	29	Farol HONDA CIVIC Mod.92 3D-4D K600 BALLADE	881.00	75	f	t	2026-07-24 14:19:44.077972+00
278	DEPO-00278	217-1111 PXA-R	217-1111 PXA	R	29	Farol HONDA CIVIC Mod.92 3D-4D K600 BALLADE	881.00	76	f	t	2026-07-24 14:19:44.077972+00
279	DEPO-00279	001-6557-R	001-6557	R	29	Farol HONDA EF	100.00	1124	f	t	2026-07-24 14:19:44.077972+00
280	DEPO-00280	221-1160-2L	221-1160-2L	\N	29	Farol HYUNDAI ACCENT SOLARIS Mod. 2011~2012~2014	538.00	945	f	t	2026-07-24 14:19:44.077972+00
281	DEPO-00281	221-1185-L	221-1185	L	29	Farol HYUNDAI i10 GRAND i10 Mod. 2013~2014~2015~2016	563.00	103	f	t	2026-07-24 14:19:44.077972+00
282	DEPO-00282	221-1185-R	221-1185	R	29	Farol HYUNDAI i10 GRAND i10 Mod. 2013~2014~2015~2016	563.00	104	f	t	2026-07-24 14:19:44.077972+00
283	DEPO-00283	221-1159-L	221-1159	L	29	Farol i10 GRAND i10 Mod. 2011~2012	416.00	101	f	t	2026-07-24 14:19:44.077972+00
284	DEPO-00284	221-1159-R	221-1159	R	29	Farol i10 GRAND i10 Mod. 2011~2012	416.00	102	f	t	2026-07-24 14:19:44.077972+00
285	DEPO-00285	333-1172-L	333-1172	L	29	Farol JEEP GRAN CHEROKEE Mod. 2005~2006~2007	596.00	125	f	t	2026-07-24 14:19:44.077972+00
286	DEPO-00286	333-1172-R	333-1172	R	29	Farol JEEP GRAN CHEROKEE Mod. 2005~2006~2007	596.00	126	f	t	2026-07-24 14:19:44.077972+00
287	DEPO-00287	323-1105-L	323-1105	L	29	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	520.00	121	f	t	2026-07-24 14:19:44.077972+00
288	DEPO-00288	323-1105-R	323-1105	R	29	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	520.00	122	f	t	2026-07-24 14:19:44.077972+00
289	DEPO-00289	323-1501-L	323-1501	L	29	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	130.00	123	f	t	2026-07-24 14:19:44.077972+00
290	DEPO-00290	323-1501-R	323-1501	R	29	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	130.00	124	f	t	2026-07-24 14:19:44.077972+00
291	DEPO-00291	214-1163-L	214-1163	L	29	Farol LANCER Mod. 2000~2001~2002	361.00	61	f	t	2026-07-24 14:19:44.077972+00
292	DEPO-00292	214-1163-R	214-1163	R	29	Farol LANCER Mod. 2000~2001~2002	361.00	62	f	t	2026-07-24 14:19:44.077972+00
293	DEPO-00293	214-1148-L	214-1148	L	29	Farol LANCER Negro Mod. 98~99~2000~2001 CK5	230.00	57	f	t	2026-07-24 14:19:44.077972+00
294	DEPO-00294	214-1148-R	214-1148	R	29	Farol LANCER Negro Mod. 98~99~2000~2001 CK5	230.00	58	f	t	2026-07-24 14:19:44.077972+00
295	DEPO-00295	12-296-L	12-296	L	29	Farol LEVIN 90	100.00	388	f	t	2026-07-24 14:19:44.077972+00
296	DEPO-00296	216-1175-L	216-1175	L	29	Farol MAZDA PICK UP BT-50 Mod.2015~2016~2017	900.00	69	f	t	2026-07-24 14:19:44.077972+00
297	DEPO-00297	216-1175-R	216-1175	R	29	Farol MAZDA PICK UP BT-50 Mod.2015~2016~2017	900.00	70	f	t	2026-07-24 14:19:44.077972+00
298	DEPO-00298	314-1126-L	314-1126	L	29	Farol Mitsubishi ECLIPSE Mod. 2000~2001~2002	424.00	113	f	t	2026-07-24 14:19:44.077972+00
299	DEPO-00299	314-1126-R	314-1126	R	29	Farol Mitsubishi ECLIPSE Mod. 2000~2001~2002	424.00	114	f	t	2026-07-24 14:19:44.077972+00
300	DEPO-00300	7524-R	7524	R	29	Farol MITSUBISHI GALANT	400.00	341	f	t	2026-07-24 14:19:44.077972+00
301	DEPO-00301	214-1159-L	214-1159	L	29	Farol MONTERO TIBURON 2000~2001~2002~2003~2004~2005~2006	640.00	59	f	t	2026-07-24 14:19:44.077972+00
302	DEPO-00302	214-1159-R	214-1159	R	29	Farol MONTERO TIBURON 2000~2001~2002~2003~2004~2005~2006	640.00	60	f	t	2026-07-24 14:19:44.077972+00
303	DEPO-00303	1299-R	1299	R	29	Farol NISSAN B13 215-1134 vidrio	100.00	343	f	t	2026-07-24 14:19:44.077972+00
304	DEPO-00304	1478-L	1478	L	29	Farol NISSAN B13 215-1154 Plastico	100.00	345	f	t	2026-07-24 14:19:44.077972+00
305	DEPO-00305	1478-R	1478	R	29	Farol NISSAN B13 215-1154 Plastico	100.00	344	f	t	2026-07-24 14:19:44.077972+00
306	DEPO-00306	1439-L	1439	L	29	Farol NISSSAN CUSTUM	150.00	347	f	t	2026-07-24 14:19:44.077972+00
307	DEPO-00307	1439-R	1439	R	29	Farol NISSSAN CUSTUM	150.00	348	f	t	2026-07-24 14:19:44.077972+00
308	DEPO-00308	553-1101-LDEM2-L	553-1101-LDEM2	L	29	Farol Renault DUSTER Mod.2013~2014~2015~2016~	544.00	135	f	t	2026-07-24 14:19:44.077972+00
309	DEPO-00309	553-1101-LDEM2-R	553-1101-LDEM2	R	29	Farol Renault DUSTER Mod.2013~2014~2015~2016~	544.00	136	f	t	2026-07-24 14:19:44.077972+00
310	DEPO-00310	551-11AK E2-L	551-11AK E2	L	29	Farol Renault KWID Mod.2017~2018~2019~2020	525.00	133	f	t	2026-07-24 14:19:44.077972+00
311	DEPO-00311	551-11AK E2-R	551-11AK E2	R	29	Farol Renault KWID Mod.2017~2018~2019~2020	525.00	134	f	t	2026-07-24 14:19:44.077972+00
312	DEPO-00312	10-66-L	10-66	L	29	Farol SRALET EP82	100.00	382	f	t	2026-07-24 14:19:44.077972+00
313	DEPO-00313	10-58-L	10-58	L	29	Farol SRALET EP82 GT 212-1152	100.00	380	f	t	2026-07-24 14:19:44.077972+00
314	DEPO-00314	10-66-R	10-66	R	29	Farol STARLET EP82	100.00	383	f	t	2026-07-24 14:19:44.077972+00
315	DEPO-00315	10-58-R	10-58	R	29	Farol STARLET EP82 GT 212-1152	100.00	381	f	t	2026-07-24 14:19:44.077972+00
316	DEPO-00316	2068-L	2068	L	29	Farol SUBARU DOMINGO	175.00	1118	f	t	2026-07-24 14:19:44.077972+00
317	DEPO-00317	2068-R	2068	R	29	Farol SUBARU DOMINGO	175.00	1119	f	t	2026-07-24 14:19:44.077972+00
318	DEPO-00318	1540-L	1540	L	29	Farol SUBARU IMPREZA	100.00	1123	f	t	2026-07-24 14:19:44.077972+00
319	DEPO-00319	220-1105-L	220-1105	L	29	Farol SUBARU IMPREZA 4D~5D Mod. 97~99	410.00	97	f	t	2026-07-24 14:19:44.077972+00
320	DEPO-00320	220-1105-R	220-1105	R	29	Farol SUBARU IMPREZA 4D~5D Mod. 97~99	410.00	98	f	t	2026-07-24 14:19:44.077972+00
321	DEPO-00321	52-016-L	52-016	L	29	Farol SUCCED	400.00	394	f	t	2026-07-24 14:19:44.077972+00
322	DEPO-00322	52-016-R	52-016	R	29	Farol SUCCED	400.00	395	f	t	2026-07-24 14:19:44.077972+00
323	DEPO-00323	100-1120-L	100-1120	L	29	Farol suelto universal p/foco cambiable H4 (tipo wagner) 2000	84.00	39	f	t	2026-07-24 14:19:44.077972+00
324	DEPO-00324	100-1120-R	100-1120	R	29	Farol suelto universal p/foco cambiable H4 (tipo wagner) 2000	84.00	40	f	t	2026-07-24 14:19:44.077972+00
325	DEPO-00325	100-1124-L/R	100-1124-L/R	\N	29	Farol suelto UNIVERSAL p/foco cambiable REDONDO CRISTAL 2000	96.00	41	f	t	2026-07-24 14:19:44.077972+00
326	DEPO-00326	218-1136-L	218-1136	L	29	Farol Suzuqui GRAND VITARA XL7 Mod.2005~2006~2007~2008	648.00	85	f	t	2026-07-24 14:19:44.077972+00
327	DEPO-00327	218-1136-R	218-1136	R	29	Farol Suzuqui GRAND VITARA XL7 Mod.2005~2006~2007~2008	648.00	86	f	t	2026-07-24 14:19:44.077972+00
328	DEPO-00328	218-1170-L	218-1170	L	29	Farol Suzuqui SWIFT Mod.2017~2018~2019~2020 ECE.ELEC	721.00	87	f	t	2026-07-24 14:19:44.077972+00
329	DEPO-00329	218-1170-R	218-1170	R	29	Farol Suzuqui SWIFT Mod.2017~2018~2019~2020 ECE.ELEC	721.00	88	f	t	2026-07-24 14:19:44.077972+00
330	DEPO-00330	05-31-L	05-31	L	29	Farol TOYOTA CALDINA GT	250.00	368	f	t	2026-07-24 14:19:44.077972+00
331	DEPO-00331	05-31-R	05-31	R	29	Farol TOYOTA CALDINA GT	250.00	369	f	t	2026-07-24 14:19:44.077972+00
332	DEPO-00332	12-428-L	12-428	L	29	Farol TOYOTA CARIB 96	200.00	370	f	t	2026-07-24 14:19:44.077972+00
333	DEPO-00333	12-428-R	12-428	R	29	Farol TOYOTA CARIB 96	200.00	371	f	t	2026-07-24 14:19:44.077972+00
334	DEPO-00334	20-145-L	20-145	L	29	Farol TOYOTA CORONA 212-1105	100.00	374	f	t	2026-07-24 14:19:44.077972+00
335	DEPO-00335	20-260-R	20-260	R	29	Farol TOYOTA CORONA 212-1138	100.00	373	f	t	2026-07-24 14:19:44.077972+00
336	DEPO-00336	1210-R	1210	R	29	Farol TOYOTA CORONA VERIFICAR BLUE BIRD 215-1145	100.00	372	f	t	2026-07-24 14:19:44.077972+00
337	DEPO-00337	26-13-L	26-13	L	29	Farol TOYOTA CUSTOM	300.00	375	f	t	2026-07-24 14:19:44.077972+00
338	DEPO-00338	26-32-L	26-32	L	29	Farol TOYOTA CUSTOM CON Guiñador	100.00	377	f	t	2026-07-24 14:19:44.077972+00
339	DEPO-00339	26-32-R	26-32	R	29	Farol TOYOTA CUSTOM CON Guiñador	100.00	378	f	t	2026-07-24 14:19:44.077972+00
340	DEPO-00340	26-13-R	26-13	R	29	Farol TOYOTA CUSTOM CUADRADO	300.00	376	f	t	2026-07-24 14:19:44.077972+00
341	DEPO-00341	32-22-R	32-22	R	29	Farol TOYOTA DESCONOCIDO	75.00	358	f	t	2026-07-24 14:19:44.077972+00
342	DEPO-00342	12-322-R	12-322	R	29	Farol TOYOTA FX	100.00	385	f	t	2026-07-24 14:19:44.077972+00
343	DEPO-00343	25-72-R	25-72	R	29	Farol TOYOTA REDONDO CON SOPORTE	75.00	400	f	t	2026-07-24 14:19:44.077972+00
344	DEPO-00344	12-342-L	12-342	L	29	Farol TRUENO 97	100.00	1043	f	t	2026-07-24 14:19:44.077972+00
345	DEPO-00345	12-342-R	12-342	R	29	Farol TRUENO 97	100.00	1044	f	t	2026-07-24 14:19:44.077972+00
346	DEPO-00346	441-1130-L	441-1130	L	29	Farol Volkswagen GOLF IV Mod.1998~1999~2000~2001~2002	365.00	955	f	t	2026-07-24 14:19:44.077972+00
347	DEPO-00347	441-1130-R	441-1130	R	29	Farol Volkswagen GOLF IV Mod.1998~1999~2000~2001~2002	365.00	956	f	t	2026-07-24 14:19:44.077972+00
348	DEPO-00348	C-3024075	C-3024075	\N	30	Filtro	37.00	1097	f	t	2026-07-24 14:19:44.077972+00
349	DEPO-00349	C-3024017	C-3024017	\N	30	Filtro de AIRE 1RZ HIACE LOBO 17801-54140-C (+CHINOS)	30.70	1104	f	t	2026-07-24 14:19:44.077972+00
350	DEPO-00350	C-3024084	C-3024084	\N	30	Filtro de AIRE 1RZ HIACE LOBO REGIUS COMMUTER KING LONG (+CHINOS)	24.40	1105	f	t	2026-07-24 14:19:44.077972+00
351	DEPO-00351	C-3024001	C-3024001	\N	30	Filtro de AIRE 4A 4AG/AE100 5A COROLLA SPACIO LEVIN SPRINTER CARIB	18.90	1102	f	t	2026-07-24 14:19:44.077972+00
352	DEPO-00352	C-3024005	C-3024005	\N	30	Filtro de AIRE COROLLA Mod. 92 ~ 2002	18.90	1101	f	t	2026-07-24 14:19:44.077972+00
353	DEPO-00353	C-3024013	C-3024013	\N	30	Filtro de aire NISSAN URBAN E24 CARAVAN C/P/aspa	27.90	1103	f	t	2026-07-24 14:19:44.077972+00
354	DEPO-00354	C-3024004	C-3024004	\N	30	Filtro de AIRE NOAH TOWNACE TACOMA PREVIA PICKUP 4RUNNER LITEACE HILUX	18.90	1100	f	t	2026-07-24 14:19:44.077972+00
355	DEPO-00355	122472	122472	\N	30	Filtro de AIRE SUZUQUI 13780-79210 EMP-265	20.00	1099	f	t	2026-07-24 14:19:44.077972+00
356	DEPO-00356	C-3024064	C-3024064	\N	30	Filtro TOYOTA HILUX VIGO 2KDFTV	40.50	165	f	t	2026-07-24 14:19:44.077972+00
357	DEPO-00357	CH-216010	CH-216010	\N	31	Foco Alogeno H4 de Farol SUPER WHITE AZULADO	9.30	1093	f	t	2026-07-24 14:19:44.077972+00
358	DEPO-00358	CH-216028	CH-216028	\N	31	Foco CUÑA moderno de 1 contacto 12V 21W Un filamento	3.50	1090	f	t	2026-07-24 14:19:44.077972+00
359	DEPO-00359	CH-216029	CH-216029	\N	31	Foco CUÑA moderno de 2 contactos 12V 21/5W. #7443 T-20 Dos filamentos	3.30	1091	f	t	2026-07-24 14:19:44.077972+00
360	DEPO-00360	CH-216036	CH-216036	\N	31	Foco de DOBLE Contacto 12V 21/5W FP5412 Dos filamentos Universal P/Stop	0.90	1092	f	t	2026-07-24 14:19:44.077972+00
361	DEPO-00361	FRONT-AD	FRONT-AD	\N	32	Frontal NISSAN AD 2004	1500.00	342	f	t	2026-07-24 14:19:44.077972+00
362	DEPO-00362	FRONT-IGNIS	FRONT-IGNIS	\N	32	Frontal SUZUKI SWIFT IMCOMPLETO IGNIS	2500.00	356	f	t	2026-07-24 14:19:44.077972+00
363	DEPO-00363	FRONT-CALDINAGT	FRONT-CALDINAGT	\N	32	Frontal TOYOTA CALDINA GT	2500.00	367	f	t	2026-07-24 14:19:44.077972+00
364	DEPO-00364	FRONT-BOXY	FRONT-BOXY	\N	32	Frontal TOYOTA NOHA BOXY	2500.00	349	f	t	2026-07-24 14:19:44.077972+00
365	DEPO-00365	SUPERKOTTE-G	SUPERKOTTE-G	\N	33	Grasa PEQUEÑA	\N	1089	f	t	2026-07-24 14:19:44.077972+00
366	DEPO-00366	GF-E24-L	GF-E24	L	35	Guardafango CHANCHO	100.00	970	f	t	2026-07-24 14:19:44.077972+00
367	DEPO-00367	GF-E24-R	GF-E24	R	35	Guardafango CHANCHO	100.00	971	f	t	2026-07-24 14:19:44.077972+00
368	DEPO-00368	GF-VITARA-L	GF-VITARA	L	35	Guardafango DE VITARA CON BUCHERA	250.00	548	f	t	2026-07-24 14:19:44.077972+00
369	DEPO-00369	GF-VITARA-R	GF-VITARA	R	35	Guardafango DE VITARA CON BUCHERA	250.00	549	f	t	2026-07-24 14:19:44.077972+00
370	DEPO-00370	12-285-L	12-285	L	36	Guinador COROLLA 90 212-1524	100.00	481	f	t	2026-07-24 14:19:44.077972+00
371	DEPO-00371	1688-R	1688	R	36	Guinador FX ANTIGUO COROLLA 2	90.00	507	f	t	2026-07-24 14:19:44.077972+00
372	DEPO-00372	210-37746-R	210-37746	R	36	Guinador PAJERO MONTERO 214-1531	100.00	412	f	t	2026-07-24 14:19:44.077972+00
373	DEPO-00373	218-1602-L	218-1602	L	36	Guinador de Parachoque Suzuki Samurai	21.00	89	f	t	2026-07-24 14:19:44.077972+00
374	DEPO-00374	218-1602-R	218-1602	R	36	Guinador de Parachoque Suzuki Samurai	21.00	90	f	t	2026-07-24 14:19:44.077972+00
375	DEPO-00375	210-37779-L	210-37779	L	36	Guiñador ECLIPSE	20.00	407	f	t	2026-07-24 14:19:44.077972+00
376	DEPO-00376	3313-R	3313	R	36	Guiñador AD 215-1561	100.00	445	f	t	2026-07-24 14:19:44.077972+00
377	DEPO-00377	05-32-L	05-32	L	36	Guiñador CALDIN GT	100.00	465	f	t	2026-07-24 14:19:44.077972+00
378	DEPO-00378	05-32-R	05-32	R	36	Guiñador CALDINA GT	100.00	466	f	t	2026-07-24 14:19:44.077972+00
379	DEPO-00379	20-317-R	20-317	R	36	Guiñador CARINA AE 91	100.00	470	f	t	2026-07-24 14:19:44.077972+00
380	DEPO-00380	20-383-L	20-383	L	36	Guiñador CARINA CRISTALIZADO	20.00	471	f	t	2026-07-24 14:19:44.077972+00
381	DEPO-00381	20-383-R	20-383	R	36	Guiñador CARINA CRISTALIZADO	20.00	472	f	t	2026-07-24 14:19:44.077972+00
382	DEPO-00382	20-262-R	20-262	R	36	Guiñador CARINA PUNTA REDONDA	35.00	488	f	t	2026-07-24 14:19:44.077972+00
383	DEPO-00383	20-197-L	20-197	L	36	Guiñador CARINA PUNTA REDONDA 212-1543	\N	489	f	t	2026-07-24 14:19:44.077972+00
384	DEPO-00384	20-197-R	20-197	R	36	Guiñador CARINA PUNTA REDONDA 212-1543	25.00	490	f	t	2026-07-24 14:19:44.077972+00
385	DEPO-00385	20-262-L	20-262	L	36	Guiñador CARINA PUNTA REDONDA 212-1557	25.00	487	f	t	2026-07-24 14:19:44.077972+00
386	DEPO-00386	12-372-L	12-372	L	36	Guiñador CERES	200.00	473	f	t	2026-07-24 14:19:44.077972+00
387	DEPO-00387	12-372-R	12-372	R	36	Guiñador CERES	200.00	474	f	t	2026-07-24 14:19:44.077972+00
388	DEPO-00388	120-87194-L	120-87194	L	36	Guiñador CHALLENGER	200.00	405	f	t	2026-07-24 14:19:44.077972+00
389	DEPO-00389	120-87194-R	120-87194	R	36	Guiñador CHALLENGER	200.00	406	f	t	2026-07-24 14:19:44.077972+00
390	DEPO-00390	16-96-L	16-96	L	36	Guiñador COROLLA 2	100.00	475	f	t	2026-07-24 14:19:44.077972+00
391	DEPO-00391	16-96-R	16-96	R	36	Guiñador COROLLA 2	100.00	476	f	t	2026-07-24 14:19:44.077972+00
392	DEPO-00392	12-197-L	12-197	L	36	Guiñador COROLLA 84 212-1611	20.00	477	f	t	2026-07-24 14:19:44.077972+00
393	DEPO-00393	12-197-R	12-197	R	36	Guiñador COROLLA 84 212-1611	20.00	478	f	t	2026-07-24 14:19:44.077972+00
394	DEPO-00394	12-412-R	12-412	R	36	Guiñador COROLLA SAPITO 212-1592	20.00	484	f	t	2026-07-24 14:19:44.077972+00
395	DEPO-00395	1469-R	1469	R	36	Guiñador CORONA 212-1605	20.00	998	f	t	2026-07-24 14:19:44.077972+00
396	DEPO-00396	120-24580-L	120-24580	L	36	Guiñador CUSTOM BLANCO 215-1575	100.00	434	f	t	2026-07-24 14:19:44.077972+00
397	DEPO-00397	120-24580-R	120-24580	R	36	Guiñador CUSTOM BLANCO 215-1575	100.00	435	f	t	2026-07-24 14:19:44.077972+00
398	DEPO-00398	20-306-L	20-306	L	36	Guiñador DE CALDINA NARANJA	100.00	467	f	t	2026-07-24 14:19:44.077972+00
399	DEPO-00399	3336-L	3336	L	36	Guiñador DE IMPREZA JAPONES	100.00	453	f	t	2026-07-24 14:19:44.077972+00
400	DEPO-00400	312-1634PXA-L	312-1634PXA	L	36	Guiñador de Parachoque CELICA 90/93 TUNNIG	124.00	111	f	t	2026-07-24 14:19:44.077972+00
401	DEPO-00401	312-1634PXA-R	312-1634PXA	R	36	Guiñador de Parachoque CELICA 90/93 TUNNIG	124.00	112	f	t	2026-07-24 14:19:44.077972+00
402	DEPO-00402	26-33-L	26-33	L	36	Guiñador DE Parachoque DE HICE 212-1664	90.00	513	f	t	2026-07-24 14:19:44.077972+00
403	DEPO-00403	26-33-R	26-33	R	36	Guiñador DE Parachoque DE HICE 212-1664	90.00	514	f	t	2026-07-24 14:19:44.077972+00
404	DEPO-00404	3353-L	3353	L	36	Guiñador DE Parachoque DOMINGO	\N	1072	f	t	2026-07-24 14:19:44.077972+00
405	DEPO-00405	3353-R	3353	R	36	Guiñador DE Parachoque DOMINGO	90.00	1073	f	t	2026-07-24 14:19:44.077972+00
406	DEPO-00406	317-1612-PTB-VS	317-1612-PTB-VS	\N	36	Guiñador de Parachoque HONDA CIVIC CRX M.90~91 SMOKE TUNNIG Par	68.00	946	f	t	2026-07-24 14:19:44.077972+00
407	DEPO-00407	317-1603-L	317-1603	L	36	Guiñador de Parachoque HONDA CIVIC Mod.88~91	30.00	119	f	t	2026-07-24 14:19:44.077972+00
408	DEPO-00408	317-1603-R	317-1603	R	36	Guiñador de Parachoque HONDA CIVIC Mod.88~91	30.00	120	f	t	2026-07-24 14:19:44.077972+00
409	DEPO-00409	3382-L	3382	L	36	Guiñador DE Parachoque JUNIOR	250.00	1116	f	t	2026-07-24 14:19:44.077972+00
410	DEPO-00410	3382-R	3382	R	36	Guiñador DE Parachoque JUNIOR	250.00	1117	f	t	2026-07-24 14:19:44.077972+00
411	DEPO-00411	217-1608-R	217-1608	R	36	Guiñador de Parachoque ONDA CIVIC 88/90 3D NARANJA	70.00	82	f	t	2026-07-24 14:19:44.077972+00
412	DEPO-00412	218-1135-R	218-1135	R	36	Guiñador de Parachoque ONDA CIVIC 88/90 3D NARANJA	880.00	84	f	t	2026-07-24 14:19:44.077972+00
413	DEPO-00413	220-1608 pxa-L	220-1608 pxa	L	36	Guiñador de Parachoque SUBARU IMPREZA Mod.99~2000	160.00	99	f	t	2026-07-24 14:19:44.077972+00
414	DEPO-00414	220-1608 pxa-R	220-1608 pxa	R	36	Guiñador de Parachoque SUBARU IMPREZA Mod.99~2000	160.00	100	f	t	2026-07-24 14:19:44.077972+00
415	DEPO-00415	016-8319-R	016-8319	R	36	Guiñador DE Parachoque TRASERO CHARIOT	100.00	1071	f	t	2026-07-24 14:19:44.077972+00
416	DEPO-00416	016-8319-L	016-8319	L	36	Guiñador DE Parachoque TRASERO CHARIOT RVR	100.00	1070	f	t	2026-07-24 14:19:44.077972+00
417	DEPO-00417	3568-C-L	3568-C	L	36	Guiñador DE SURF BLANCO	200.00	531	f	t	2026-07-24 14:19:44.077972+00
418	DEPO-00418	3568-C-R	3568-C	R	36	Guiñador DE SURF BLANCO	200.00	532	f	t	2026-07-24 14:19:44.077972+00
419	DEPO-00419	2165-R	2165	R	36	Guiñador DOMINGO	150.00	450	f	t	2026-07-24 14:19:44.077972+00
420	DEPO-00420	10-76-L	10-76	L	36	Guiñador EP 82 212-1586	20.00	497	f	t	2026-07-24 14:19:44.077972+00
421	DEPO-00421	10-76-R	10-76	R	36	Guiñador EP 82 212-15A0	20.00	499	f	t	2026-07-24 14:19:44.077972+00
422	DEPO-00422	10-64-L	10-64	L	36	Guiñador EP 82 212-1582	20.00	500	f	t	2026-07-24 14:19:44.077972+00
423	DEPO-00423	10-64-R	10-64	R	36	Guiñador EP 82 212-1582	20.00	501	f	t	2026-07-24 14:19:44.077972+00
424	DEPO-00424	10-67-L	10-67	L	36	Guiñador EP 82 212-1586	20.00	496	f	t	2026-07-24 14:19:44.077972+00
425	DEPO-00425	10-67-R	10-67	R	36	Guiñador EP 82 212-15A0	20.00	498	f	t	2026-07-24 14:19:44.077972+00
426	DEPO-00426	35-43-L	35-43	L	36	Guiñador HILUX 212-1539	70.00	515	f	t	2026-07-24 14:19:44.077972+00
427	DEPO-00427	35-43-R	35-43	R	36	Guiñador HILUX 212-1539	80.00	516	f	t	2026-07-24 14:19:44.077972+00
428	DEPO-00428	21-35-L	21-35	L	36	Guiñador LATERAL CALDINA GT	100.00	987	f	t	2026-07-24 14:19:44.077972+00
429	DEPO-00429	21-35-R	21-35	R	36	Guiñador LATERAL CALDINA GT	100.00	988	f	t	2026-07-24 14:19:44.077972+00
430	DEPO-00430	36401-8500-L	36401-8500	L	36	Guiñador LATERAL CARRY	20.00	995	f	t	2026-07-24 14:19:44.077972+00
431	DEPO-00431	36401-8500-R	36401-8500	R	36	Guiñador LATERAL CARRY	20.00	996	f	t	2026-07-24 14:19:44.077972+00
432	DEPO-00432	2155-L	2155	L	36	Guiñador LATERAL FORESTER 97-2000	20.00	993	f	t	2026-07-24 14:19:44.077972+00
433	DEPO-00433	2155-R	2155	R	36	Guiñador LATERAL FORESTER 97-2000	20.00	994	f	t	2026-07-24 14:19:44.077972+00
434	DEPO-00434	3162-L	3162	L	36	Guiñador lateral RAV 4 Mod. 97 ~ 2000 212-1409	25.00	985	f	t	2026-07-24 14:19:44.077972+00
435	DEPO-00435	3162-R	3162	R	36	Guiñador lateral RAV 4 Mod. 97 ~ 2000 212-1409	25.00	986	f	t	2026-07-24 14:19:44.077972+00
436	DEPO-00436	2175-L	2175	L	36	Guiñador LATERAL SUBARU IMPREZA	25.00	989	f	t	2026-07-24 14:19:44.077972+00
437	DEPO-00437	2175-R	2175	R	36	Guiñador LATERAL SUBARU IMPREZA	25.00	990	f	t	2026-07-24 14:19:44.077972+00
438	DEPO-00438	1132-215-L	1132-215	L	36	Guiñador LATERLA LANCER 92	25.00	991	f	t	2026-07-24 14:19:44.077972+00
439	DEPO-00439	1132-215-R	1132-215	R	36	Guiñador LATERLA LANCER 92	25.00	992	f	t	2026-07-24 14:19:44.077972+00
440	DEPO-00440	12-422-L	12-422	L	36	Guiñador LEVIN 96	100.00	519	f	t	2026-07-24 14:19:44.077972+00
441	DEPO-00441	12-422-R	12-422	R	36	Guiñador LEVIN 96	100.00	520	f	t	2026-07-24 14:19:44.077972+00
442	DEPO-00442	210-87233-L	210-87233	L	36	Guiñador MONTERO	100.00	409	f	t	2026-07-24 14:19:44.077972+00
443	DEPO-00443	210-87233-R	210-87233	R	36	Guiñador MONTERO	100.00	410	f	t	2026-07-24 14:19:44.077972+00
444	DEPO-00444	3337-L	3337	L	36	Guiñador NISSAN ATLAS 215-1571	150.00	418	f	t	2026-07-24 14:19:44.077972+00
445	DEPO-00445	3337-R	3337	R	36	Guiñador NISSAN ATLAS 215-1571	150.00	419	f	t	2026-07-24 14:19:44.077972+00
446	DEPO-00446	3226-L	3226	L	36	Guiñador NISSAN CUSTOM 315-1616	100.00	441	f	t	2026-07-24 14:19:44.077972+00
447	DEPO-00447	3226-R	3226	R	36	Guiñador NISSAN CUSTOM 315-1616	100.00	442	f	t	2026-07-24 14:19:44.077972+00
448	DEPO-00448	5183-L	5183	L	36	Guiñador NISSAN SUNNY B12 NARANJA	25.00	423	f	t	2026-07-24 14:19:44.077972+00
449	DEPO-00449	5183-R	5183	R	36	Guiñador NISSAN SUNNY B12 NARANJA	25.00	424	f	t	2026-07-24 14:19:44.077972+00
450	DEPO-00450	3311-L	3311	L	36	Guiñador NISSAN SUNNY B13 215-1542	25.00	428	f	t	2026-07-24 14:19:44.077972+00
451	DEPO-00451	3311-R	3311	R	36	Guiñador NISSAN SUNNY B13 215-1542	25.00	429	f	t	2026-07-24 14:19:44.077972+00
452	DEPO-00452	3339-L	3339	L	36	Guiñador NISSAN SUNNY B13 215-1562	25.00	430	f	t	2026-07-24 14:19:44.077972+00
453	DEPO-00453	3339-R	3339	R	36	Guiñador NISSAN SUNNY B13 215-1562	25.00	431	f	t	2026-07-24 14:19:44.077972+00
454	DEPO-00454	210-63317-R	210-63317	R	36	Guiñador PRIMERA	50.00	446	f	t	2026-07-24 14:19:44.077972+00
455	DEPO-00455	10-83-L	10-83	L	36	Guiñador REFLEX EP 91 212-15A1-C	50.00	502	f	t	2026-07-24 14:19:44.077972+00
456	DEPO-00456	10-83-R	10-83	R	36	Guiñador REFLEX EP 91 212-15A1-C	50.00	503	f	t	2026-07-24 14:19:44.077972+00
457	DEPO-00457	9206-L	9206	L	36	Guiñador SERENA	100.00	447	f	t	2026-07-24 14:19:44.077972+00
458	DEPO-00458	2165-L	2165	L	36	Guiñador SUBARU DOMINGO	100.00	449	f	t	2026-07-24 14:19:44.077972+00
459	DEPO-00459	220-1402-PXA-2-L	220-1402-PXA-2	L	36	Guiñador Subaru FORESTER Mod. 98~2005 USA LED Negro. PAR	125.00	1196	f	t	2026-07-24 14:19:44.077972+00
460	DEPO-00460	220-1402-PXA-2-R	220-1402-PXA-2	R	36	Guiñador Subaru FORESTER Mod. 98~2005 USA LED Negro. PAR	125.00	1197	f	t	2026-07-24 14:19:44.077972+00
461	DEPO-00461	3200-L	3200	L	36	Guiñador SUNNY B11 BLANCO	50.00	420	f	t	2026-07-24 14:19:44.077972+00
462	DEPO-00462	3200-R	3200	R	36	Guiñador SUNNY B11 BLANCO	50.00	421	f	t	2026-07-24 14:19:44.077972+00
463	DEPO-00463	35-52-L	35-52	L	36	Guiñador SURF AMARILLO 212-1573	100.00	535	f	t	2026-07-24 14:19:44.077972+00
464	DEPO-00464	3568-Y-L	3568-Y	L	36	Guiñador SURFNARANJA	200.00	533	f	t	2026-07-24 14:19:44.077972+00
465	DEPO-00465	3568-Y-R	3568-Y	R	36	Guiñador SURFNARANJA	200.00	534	f	t	2026-07-24 14:19:44.077972+00
466	DEPO-00466	5127-L	5127	L	36	Guiñador SUZUKI MARUTI 218-1503	25.00	965	f	t	2026-07-24 14:19:44.077972+00
467	DEPO-00467	28-37-R	28-37	R	36	Guiñador TONACE	25.00	538	f	t	2026-07-24 14:19:44.077972+00
468	DEPO-00468	26-34-L	26-34	L	36	Guiñador TOYOTA CUSTOM LARGO	25.00	439	f	t	2026-07-24 14:19:44.077972+00
469	DEPO-00469	12-291-R	12-291	R	36	Guiñador TOYOTA FX	100.00	504	f	t	2026-07-24 14:19:44.077972+00
470	DEPO-00470	28-74-L	28-74	L	36	Guinador LITEACE CUSTOM 212-1568-Y	100.00	521	f	t	2026-07-24 14:19:44.077972+00
471	DEPO-00471	12-324-L	12-324	L	36	Guinador COROLLA 90 212-1647	100.00	479	f	t	2026-07-24 14:19:44.077972+00
472	DEPO-00472	12-324-R	12-324	R	36	Guinador COROLLA 90 212-1647	20.00	480	f	t	2026-07-24 14:19:44.077972+00
473	DEPO-00473	20-271-L	20-271	L	36	Guinador CORON EN PUNTA	35.00	485	f	t	2026-07-24 14:19:44.077972+00
474	DEPO-00474	20-271-R	20-271	R	36	Guinador CORON EN PUNTA	35.00	486	f	t	2026-07-24 14:19:44.077972+00
475	DEPO-00475	GF-MONTERO90-L	GF-MONTERO90	L	35	Guardafango MONTERO 90	200.00	546	f	t	2026-07-24 14:19:44.077972+00
476	DEPO-00476	GF-MONTERO90-R	GF-MONTERO90	R	35	Guardafango MONTERO 90	200.00	547	f	t	2026-07-24 14:19:44.077972+00
477	DEPO-00477	JAL-M-VAR	JAL-M-VAR	\N	37	Jalador DE MANO VARIOS	1.00	1006	f	t	2026-07-24 14:19:44.077972+00
478	DEPO-00478	PPE-PA	PPE-PA	\N	37	Jalador SUBARU DE Puerta DELANTERA	100.00	917	f	t	2026-07-24 14:19:44.077972+00
479	DEPO-00479	850032	850032	\N	39	Junta 20*35*23 AE100	119.00	1185	f	t	2026-07-24 14:19:44.077972+00
480	DEPO-00480	850027	850027	\N	39	Junta IPSUM COROLLA Mod 87~95 24 X56X 26 C/ABS 133221	115.00	1088	f	t	2026-07-24 14:19:44.077972+00
481	DEPO-00481	123229	123229	\N	39	Junta PATHFINDER PICK UP 6 Cyl. Mod 89~97 28 X50X 27	15.00	1154	f	t	2026-07-24 14:19:44.077972+00
482	DEPO-00482	SCOOTER-LL	SCOOTER-LL	\N	40	Llanta SCOOTER VERDE	200.00	868	f	t	2026-07-24 14:19:44.077972+00
483	DEPO-00483	LP-VAR	LP-VAR	\N	41	Luz DE PLACA VARIOS NEGRO	1.00	999	f	t	2026-07-24 14:19:44.077972+00
484	DEPO-00484	13-19	13-19	\N	41	Luz DE RETRO HILUX SURF 92	20.00	997	f	t	2026-07-24 14:19:44.077972+00
485	DEPO-00485	PH8A	PH8A	\N	30	Filtro de ACEITE 3/4 X 16 PH8-TH8A. C-3024087	12.50	1107	f	t	2026-07-24 14:19:44.077972+00
486	DEPO-00486	PH966	PH966	\N	30	Filtro de ACEITE PH-966B 3/4 X16 PH-201A. C-3024086	8.00	1106	f	t	2026-07-24 14:19:44.077972+00
487	DEPO-00487	MA-CALDINAGT	MA-CALDINAGT	\N	42	Maletera CALDINA GT	700.00	588	f	t	2026-07-24 14:19:44.077972+00
488	DEPO-00488	MA-CARIB98	MA-CARIB98	\N	42	Maletera CARIB 98	700.00	1008	f	t	2026-07-24 14:19:44.077972+00
489	DEPO-00489	MA-EVO6	MA-EVO6	\N	42	Maletera COMPLETA EVOLUCION 6	1800.00	1004	f	t	2026-07-24 14:19:44.077972+00
490	DEPO-00490	MA-CHARIOT	MA-CHARIOT	\N	42	Maletera MITSUBISHI CHARIOT GRANDIS	500.00	553	f	t	2026-07-24 14:19:44.077972+00
491	DEPO-00491	MA-IMPREZA	MA-IMPREZA	\N	42	Maletera SUBARU WAGON IMPREZA	700.00	586	f	t	2026-07-24 14:19:44.077972+00
492	DEPO-00492	MA-CALDINA	MA-CALDINA	\N	42	Maletera TOYOTA CALDINA A MUELLE	700.00	587	f	t	2026-07-24 14:19:44.077972+00
493	DEPO-00493	MA-VITARA	MA-VITARA	\N	42	Maletera Suzuki vitara A MUELLE	700.00	587	f	t	2026-07-24 14:19:44.077972+00
494	DEPO-00494	MA-IPSUM	MA-IPSUM	\N	42	Maletera TOYOTA IPSUM 96	500.00	579	f	t	2026-07-24 14:19:44.077972+00
495	DEPO-00495	MA-CHAN	MA-CHAN	\N	42	Maletera NISSAN CARAVAN CHANCHO	1400.00	558	f	t	2026-07-24 14:19:44.077972+00
496	DEPO-00496	MA-FORESTER2000	MA-FORESTER2000	\N	42	Maletera SUBARU FORESTER 2000	2900.00	585	f	t	2026-07-24 14:19:44.077972+00
497	DEPO-00497	62310-70N00	62310-70N00	\N	49	Mascara A VENIR AD 96 VERIFICAR	100.00	1083	f	t	2026-07-24 14:19:44.077972+00
498	DEPO-00498	53111-97503	53111-97503	\N	49	Mascara ATRAIL Blanco	100.00	556	f	t	2026-07-24 14:19:44.077972+00
499	DEPO-00499	53111-13120	53111-13120	\N	49	Mascara CARIB	150.00	573	f	t	2026-07-24 14:19:44.077972+00
500	DEPO-00500	M-CARINA-C	M-CARINA-C	\N	49	Mascara CARINA 85 CROMADO	100.00	1058	f	t	2026-07-24 14:19:44.077972+00
501	DEPO-00501	M-CARINA-B	M-CARINA-B	\N	49	Mascara CARINA 85 NEGRO	100.00	1059	f	t	2026-07-24 14:19:44.077972+00
502	DEPO-00502	53101-20340	53101-20340	\N	49	Mascara CARINA 89	100.00	572	f	t	2026-07-24 14:19:44.077972+00
503	DEPO-00503	53111-95J02	53111-95J02	\N	49	Mascara TOYOTA HIACE CUSTOM 92	100.00	575	f	t	2026-07-24 14:19:44.077972+00
504	DEPO-00504	62310-VE000	62310-VE000	\N	49	Mascara CARAVAN K20 CROMADO	100.00	576	f	t	2026-07-24 14:19:44.077972+00
505	DEPO-00505	53111-95J25	53111-95J25	\N	49	Mascara CUSTOM CROMADO GUIADOR LARGO	100.00	577	f	t	2026-07-24 14:19:44.077972+00
506	DEPO-00506	62310-38N10	62310-38N10	\N	49	Mascara CUSTUM CROMADO CON NEGRO 215-1575	100.00	560	f	t	2026-07-24 14:19:44.077972+00
507	DEPO-00507	DS07050GA-U	DS07050GA-U	\N	49	Mascara DS07050GA SUNNY B11	100.00	1054	f	t	2026-07-24 14:19:44.077972+00
508	DEPO-00508	55101-26020	55101-26020	\N	49	Mascara GRAN VIA 98	100.00	1055	f	t	2026-07-24 14:19:44.077972+00
509	DEPO-00509	53100-95J09	53100-95J09	\N	49	Mascara HIACE CUSTOM 89 212-1221 TY07081GA	100.00	574	f	t	2026-07-24 14:19:44.077972+00
510	DEPO-00510	TY07081GA	TY07081GA	\N	49	Mascara HIACE Mod 85/89 minibus TY07081GA TONG YANG	\N	1056	f	t	2026-07-24 14:19:44.077972+00
511	DEPO-00511	53114-12060	53114-12060	\N	49	Mascara LEVIN AE 86	100.00	580	f	t	2026-07-24 14:19:44.077972+00
512	DEPO-00512	53111-1A140	53111-1A140	\N	49	Mascara MARINO TOYOTA	100.00	581	f	t	2026-07-24 14:19:44.077972+00
513	DEPO-00513	MB645720	MB645720	\N	49	Mascara MITSUBISHI MONTERO NEGRO	300.00	555	f	t	2026-07-24 14:19:44.077972+00
514	DEPO-00514	63320-K74151-L	63320-K74151	L	49	Mascara NISSAN MARCH	125.00	561	f	t	2026-07-24 14:19:44.077972+00
515	DEPO-00515	63330-K74151-R	63330-K74151	R	49	Mascara NISSAN MARCH	125.00	562	f	t	2026-07-24 14:19:44.077972+00
516	DEPO-00516	53111-88110	53111-88110	\N	49	Mascara STOUT TY07023	100.00	1053	f	t	2026-07-24 14:19:44.077972+00
517	DEPO-00517	72111-51010	72111-51010	\N	49	Mascara SUZUKI SAMURAI	100.00	567	f	t	2026-07-24 14:19:44.077972+00
518	DEPO-00518	53101-13011-TW	53101-13011-TW	\N	49	Mascara TOYOTA 212-1228 CE-96	100.00	570	f	t	2026-07-24 14:19:44.077972+00
519	DEPO-00519	53101-20200	53101-20200	\N	49	Mascara TOYOTA CARIN A	100.00	571	f	t	2026-07-24 14:19:44.077972+00
520	DEPO-00520	10300-0310	10300-0310	\N	49	Mascara TOYOTA ESTARLET	100.00	582	f	t	2026-07-24 14:19:44.077972+00
521	DEPO-00521	TY-2001	TY-2001	\N	49	Mascara TOYOTA HIACE 212-1196	100.00	578	f	t	2026-07-24 14:19:44.077972+00
522	DEPO-00522	62310-VW100	62310-VW100	\N	49	Mascara URVAN E25 215-11A5	100.00	1057	f	t	2026-07-24 14:19:44.077972+00
523	DEPO-00523	DS07117GA	DS07117GA	\N	49	Mascara URVAN TYG	100.00	564	f	t	2026-07-24 14:19:44.077972+00
524	DEPO-00524	MASC-VAR	MASC-VAR	\N	49	Mascara VARIOS	100.00	1052	f	t	2026-07-24 14:19:44.077972+00
525	DEPO-00525	72111-77E00	72111-77E00	\N	49	Mascara VITARA VRS AMERICANA	100.00	566	f	t	2026-07-24 14:19:44.077972+00
526	DEPO-00526	53101-52060	53101-52060	\N	49	Mascara VITZ	100.00	583	f	t	2026-07-24 14:19:44.077972+00
527	DEPO-00527	62310-38N00	62310-38N00	\N	49	Mascara CUSTOM NISSAN CROMADO 215-1575	100.00	559	f	t	2026-07-24 14:19:44.077972+00
528	DEPO-00528	M-DATSUN	M-DATSUN	\N	49	Mascara DATSUN DOBLE Farol REDONDO	100.00	552	f	t	2026-07-24 14:19:44.077972+00
529	DEPO-00529	MB-CALDINA	MB-CALDINA	\N	44	Mataburro Caldina 98	700.00	1202	f	t	2026-07-24 14:19:44.077972+00
530	DEPO-00530	MB-MONTERO	MB-MONTERO	\N	44	Mataburro MONTERO 90	700.00	1203	f	t	2026-07-24 14:19:44.077972+00
531	DEPO-00531	PP-T10	PP-T10	\N	44	Mataburro PLASTICO SURF	100.00	584	f	t	2026-07-24 14:19:44.077972+00
532	DEPO-00532	3320-L	3320	L	45	Media luz BONGO NARANJA	200.00	1060	f	t	2026-07-24 14:19:44.077972+00
533	DEPO-00533	3320-R	3320	R	45	Media luz BONGO NARANJA	200.00	1061	f	t	2026-07-24 14:19:44.077972+00
534	DEPO-00534	212-1611-L	212-1611	L	45	Media luz c/Guiñador COROLLA Mod. 84~85~86	\N	1074	f	t	2026-07-24 14:19:44.077972+00
535	DEPO-00535	212-1611-R	212-1611	R	45	Media luz c/Guiñador COROLLA Mod. 84~85~86	\N	1075	f	t	2026-07-24 14:19:44.077972+00
536	DEPO-00536	212-1561-K-L	212-1561-K	L	45	Media luz COROLLA Mod.92~93~94~95	25.00	45	f	t	2026-07-24 14:19:44.077972+00
537	DEPO-00537	212-1561-K-R	212-1561-K	R	45	Media luz COROLLA Mod.92~93~94~95	25.00	46	f	t	2026-07-24 14:19:44.077972+00
538	DEPO-00538	212-15D8-K-L	212-15D8-K	L	45	Media luz COROLLA Mod.92~99	20.00	49	f	t	2026-07-24 14:19:44.077972+00
539	DEPO-00539	212-15D8-K-R	212-15D8-K	R	45	Media luz COROLLA Mod.92~99	20.00	50	f	t	2026-07-24 14:19:44.077972+00
540	DEPO-00540	32-41-L	32-41	L	45	Media luz DESCONOCIDO	1.00	964	f	t	2026-07-24 14:19:44.077972+00
541	DEPO-00541	214-1515-C-R	214-1515-C	R	45	Media luz GALANT Mod.89~90~91~92~93 E33A	77.00	66	f	t	2026-07-24 14:19:44.077972+00
542	DEPO-00542	214-1515-CY-L	214-1515-CY	L	45	Media luz GALANT Mod.89~90~91~92~93 E33A	70.00	63	f	t	2026-07-24 14:19:44.077972+00
543	DEPO-00543	214-1515-CY-R	214-1515-CY	R	45	Media luz GALANT Mod.89~90~91~92~93 E33A	70.00	64	f	t	2026-07-24 14:19:44.077972+00
544	DEPO-00544	26-37-L	26-37	L	45	Media luz HIACE CUSTOM 96-2000	100.00	523	f	t	2026-07-24 14:19:44.077972+00
545	DEPO-00545	26-37-R	26-37	R	45	Media luz HIACE CUSTOM 96-2000	100.00	524	f	t	2026-07-24 14:19:44.077972+00
546	DEPO-00546	217-1519-L	217-1519	L	45	Media luz HONDA ACCORD Mod.90~91	35.00	77	f	t	2026-07-24 14:19:44.077972+00
547	DEPO-00547	045-3966-L	045-3966	L	45	Media luz HONDA CIVIC 217-1520	75.00	1068	f	t	2026-07-24 14:19:44.077972+00
548	DEPO-00548	045-3966-R	045-3966	R	45	Media luz HONDA CIVIC 217-1520	75.00	1069	f	t	2026-07-24 14:19:44.077972+00
549	DEPO-00549	217-1522-L	217-1522	L	45	Media luz HONDA CIVIC Mod.90 3D	60.00	79	f	t	2026-07-24 14:19:44.077972+00
550	DEPO-00550	217-1522-R	217-1522	R	45	Media luz HONDA CIVIC Mod.90 3D	60.00	80	f	t	2026-07-24 14:19:44.077972+00
551	DEPO-00551	317-1522-L	317-1522	L	45	Media luz HONDA PRELUDE Mod. 92 ~ 96	60.00	117	f	t	2026-07-24 14:19:44.077972+00
552	DEPO-00552	317-1522-R	317-1522	R	45	Media luz HONDA PRELUDE Mod. 92 ~ 96	60.00	118	f	t	2026-07-24 14:19:44.077972+00
553	DEPO-00553	214-1529-PXA-2-L	214-1529-PXA-2	L	45	Media luz LANCER Mod. 93~94~95~96 NEGRO	126.30	1194	f	t	2026-07-24 14:19:44.077972+00
554	DEPO-00554	214-1529-PXA-2-R	214-1529-PXA-2	R	45	Media luz LANCER Mod. 93~94~95~96 NEGRO	126.30	1195	f	t	2026-07-24 14:19:44.077972+00
555	DEPO-00555	P0371-L	P0371	L	45	Media luz MAZDA BONGO Mod.2000~2001~2002 VANETTE E2000 216-1555	200.00	1125	f	t	2026-07-24 14:19:44.077972+00
556	DEPO-00556	P0371-R	P0371	R	45	Media luz MAZDA BONGO Mod.2000~2001~2002 VANETTE E2000 216-1555	200.00	1126	f	t	2026-07-24 14:19:44.077972+00
557	DEPO-00557	18-1800-R	18-1800	R	45	Media luz MITSIBISHI VERIFICAR	20.00	1064	f	t	2026-07-24 14:19:44.077972+00
558	DEPO-00558	5726-L	5726	L	45	Media luz MITSIBISHI VERIFICAR	20.00	1063	f	t	2026-07-24 14:19:44.077972+00
559	DEPO-00559	215-1552-L	215-1552	L	45	Media luz Nissan BLUE BIRD Mod. 90-93(Auto)	79.00	947	f	t	2026-07-24 14:19:44.077972+00
560	DEPO-00560	215-1552-R	215-1552	R	45	Media luz Nissan BLUE BIRD Mod. 90-93(Auto)	79.00	948	f	t	2026-07-24 14:19:44.077972+00
561	DEPO-00561	120-63437-L	120-63437	L	45	Media luz PATHFINDER REGULOS	100.00	1065	f	t	2026-07-24 14:19:44.077972+00
562	DEPO-00562	120-63437-R	120-63437	R	45	Media luz PATHFINDER REGULOS	100.00	1066	f	t	2026-07-24 14:19:44.077972+00
563	DEPO-00563	3429-L	3429	L	45	Media luz PRESEA VERIFICAR BLUE BIRD	100.00	1078	f	t	2026-07-24 14:19:44.077972+00
564	DEPO-00564	3429-R	3429	R	45	Media luz PRESEA VERIFICAR BLUE BIRD	100.00	1079	f	t	2026-07-24 14:19:44.077972+00
565	DEPO-00565	212-63141-L	212-63141	L	45	Media luz SUNNY B11	20.00	1077	f	t	2026-07-24 14:19:44.077972+00
566	DEPO-00566	212-32284-R	212-32284	R	45	Media luz SUZUKI SWIF VERIFICAR	20.00	1062	f	t	2026-07-24 14:19:44.077972+00
567	DEPO-00567	28-77-R	28-77	R	45	Media luz TOWN ACE 78	25.00	1121	f	t	2026-07-24 14:19:44.077972+00
568	DEPO-00568	28-77-L	28-77	L	45	Media luz TOWN ACE 78	25.00	1120	f	t	2026-07-24 14:19:44.077972+00
569	DEPO-00569	312-1521-L	312-1521	L	45	Media luz Toyota 4RUNNER Mod. 96	123.00	109	f	t	2026-07-24 14:19:44.077972+00
570	DEPO-00570	312-1521-R	312-1521	R	45	Media luz Toyota 4RUNNER Mod. 96	123.00	110	f	t	2026-07-24 14:19:44.077972+00
571	DEPO-00571	212-1616-R	212-1616	R	45	Media luz Toyota HIACE Mod.84~89	\N	1076	f	t	2026-07-24 14:19:44.077972+00
572	DEPO-00572	212-1549-R	212-1549	R	45	Media luz Toyota HIACE Mod.90~02	35.00	44	f	t	2026-07-24 14:19:44.077972+00
573	DEPO-00573	28-79-L	28-79	L	45	Media luz TOYOTA LITE ACE 212-1516 MOD 82	25.00	895	f	t	2026-07-24 14:19:44.077972+00
574	DEPO-00574	28-79-R	28-79	R	45	Media luz TOYOTA LITE ACE 212-1516 MOD 82	25.00	894	f	t	2026-07-24 14:19:44.077972+00
575	DEPO-00575	28-112-R	28-112	R	45	Media luz Toyota NOAH Mod.96~97~98 212-15H2-K	20.00	1067	f	t	2026-07-24 14:19:44.077972+00
576	DEPO-00576	860067	860067	\N	48	Muñón de dirección / Terminal YOITOKI. SE-2651	19.00	1166	f	t	2026-07-24 14:19:44.077972+00
577	DEPO-00577	MD-VARIOS	MD-VARIOS	\N	48	Muñon DE DIRECCION VARIOS	1.00	1011	f	t	2026-07-24 14:19:44.077972+00
578	DEPO-00578	860019	860019	\N	48	Muñon de Estabilizador ilizador RUNNER YOITOKI Universal	21.00	1161	f	t	2026-07-24 14:19:44.077972+00
579	DEPO-00579	MS-VARIOS	MS-VARIOS	\N	48	Muñon DE SUSPENCION VARIOS	1.00	1012	f	t	2026-07-24 14:19:44.077972+00
580	DEPO-00580	860057	860057	\N	48	Muñon de suspensión NOAH ~ LITEACE Superior YOITOKI Sin grasera blindado	45.00	1148	f	t	2026-07-24 14:19:44.077972+00
581	DEPO-00581	860062	860062	\N	48	Muñon de suspension VANETTE BONGO Superior 00-06	47.00	1149	f	t	2026-07-24 14:19:44.077972+00
582	DEPO-00582	860070	860070	\N	48	Muñon DIRECCION 124848	21.00	1163	f	t	2026-07-24 14:19:44.077972+00
583	DEPO-00583	860069	860069	\N	48	Muñon DIRECCION CALDINA R	33.00	1160	f	t	2026-07-24 14:19:44.077972+00
584	DEPO-00584	23521	23521	\N	48	Muñon DIRECCION COROLLA 78	1.00	1174	f	t	2026-07-24 14:19:44.077972+00
585	DEPO-00585	860090	860090	\N	48	Muñon DIRECCION HIACE CHINO ROSCA 15	30.00	26	f	t	2026-07-24 14:19:44.077972+00
586	DEPO-00586	124848	124848	\N	48	Muñon DIRECCION HIACE CUADRADO /HILUX 89	25.00	4	f	t	2026-07-24 14:19:44.077972+00
587	DEPO-00587	ALICMD-002	ALICMD-002	\N	48	Muñon DIRECCION HIACE ROSCA 15	25.00	1153	f	t	2026-07-24 14:19:44.077972+00
588	DEPO-00588	860071	860071	\N	48	Muñon DIRECCION LOBO ROSCA 17	25.00	23	f	t	2026-07-24 14:19:44.077972+00
589	DEPO-00589	860129	860129	\N	48	Muñon DIRECCION LUCIDA	23.00	27	f	t	2026-07-24 14:19:44.077972+00
590	DEPO-00590	860128	860128	\N	48	Muñon DIRECCION NISSAN LUCIDA	23.00	1167	f	t	2026-07-24 14:19:44.077972+00
591	DEPO-00591	860073	860073	\N	48	Muñon DIRECCION PROBOX	32.00	25	f	t	2026-07-24 14:19:44.077972+00
592	DEPO-00592	860142	860142	\N	48	Muñon DIRECCION SUZUKI SX4 SWIFT	21.00	1152	f	t	2026-07-24 14:19:44.077972+00
593	DEPO-00593	860027	860027	\N	48	Muñon Estabilizador largo NOAH SUZUKI	22.00	8	f	t	2026-07-24 14:19:44.077972+00
594	DEPO-00594	860101	860101	\N	48	Muñon Estabilizador PROBOX	23.00	1151	f	t	2026-07-24 14:19:44.077972+00
595	DEPO-00595	R-KEYTON	R-KEYTON	\N	48	Muñon KEYTON	28.00	1139	f	t	2026-07-24 14:19:44.077972+00
596	DEPO-00596	860143	860143	\N	48	Muñon KING LONG	26.00	1140	f	t	2026-07-24 14:19:44.077972+00
597	DEPO-00597	860121	860121	\N	48	Muñon Muñon RUNNER	25.00	1168	f	t	2026-07-24 14:19:44.077972+00
598	DEPO-00598	860144	860144	\N	48	Muñon SIRECCION KING LONG ROSCA 14	25.00	1150	f	t	2026-07-24 14:19:44.077972+00
599	DEPO-00599	860043	860043	\N	48	Muñon SUSPENCIO HIACE INFERIOR	45.00	17	f	t	2026-07-24 14:19:44.077972+00
600	DEPO-00600	860060	860060	\N	48	Muñon SUSPENCION NISSAN CHANCHO	60.00	21	f	t	2026-07-24 14:19:44.077972+00
601	DEPO-00601	860048	860048	\N	48	Muñon SUSPENO DEL PROBOX	25.00	20	f	t	2026-07-24 14:19:44.077972+00
602	DEPO-00602	860039	860039	\N	48	Muñon SUSPENSIÓN CALDINA 97	30.00	14	f	t	2026-07-24 14:19:44.077972+00
603	DEPO-00603	860037	860037	\N	48	Muñon SUSPENSIÓN COROLLA 90 L	30.00	13	f	t	2026-07-24 14:19:44.077972+00
604	DEPO-00604	860036	860036	\N	48	Muñon SUSPENSIÓN COROLLA 90 R	30.00	12	f	t	2026-07-24 14:19:44.077972+00
605	DEPO-00605	860064	860064	\N	48	Muñon SUSPENSION HIACE CUADRADO	48.00	22	f	t	2026-07-24 14:19:44.077972+00
606	DEPO-00606	43350-39125	43350-39125	\N	48	Muñon SUSPENSIÓN HIALUX 92 SUPERIOR MARCA BIG	43.00	1156	f	t	2026-07-24 14:19:44.077972+00
607	DEPO-00607	860047	860047	\N	48	Muñon SUSPENSIÓN INFERIOR NOAH LITE ACE	33.00	1155	f	t	2026-07-24 14:19:44.077972+00
608	DEPO-00608	43310-39016	43310-39016	\N	48	Muñon SUSPENSIÓN LAND CRUISER	70.00	1176	f	t	2026-07-24 14:19:44.077972+00
609	DEPO-00609	860041	860041	\N	48	Muñon SUSPENSIÓN MINIBUS URVAN 90 ABAJO	33.00	15	f	t	2026-07-24 14:19:44.077972+00
610	DEPO-00610	860042	860042	\N	48	Muñon SUSPENSIÓN MINIUS NISSAN URVAN 90	33.00	16	f	t	2026-07-24 14:19:44.077972+00
611	DEPO-00611	860046	860046	\N	48	Muñon SUSPENSIÓN RAV 4	36.00	18	f	t	2026-07-24 14:19:44.077972+00
612	DEPO-00612	43330-39245-INF	43330-39245-INF	\N	48	Muñon TOYOTA HILUX STOUT INFERIOR	45.00	1183	f	t	2026-07-24 14:19:44.077972+00
613	DEPO-00613	43330-39245-SUP	43330-39245-SUP	\N	48	Muñon TOYOTA HILUX STOUT SUPERIOR	45.00	1184	f	t	2026-07-24 14:19:44.077972+00
614	DEPO-00614	860072	860072	\N	47	MuñonES SUSPENSIÓN PROBOX ISQUIERDO	23.00	24	f	t	2026-07-24 14:19:44.077972+00
615	DEPO-00615	8109-L	8109	L	59	RETROVISOR NISSAN SKYLINE R32	75.00	257	f	t	2026-07-24 14:19:44.077972+00
616	DEPO-00616	8109-R	8109	R	59	RETROVISOR NISSAN SKYLINE R32	75.00	258	f	t	2026-07-24 14:19:44.077972+00
617	DEPO-00617	N26-L	N26	L	59	Retrovisor Nissan Silvina 513	75.00	256	f	t	2026-07-24 14:19:44.077972+00
618	DEPO-00618	223604	223604	\N	50	Parachoque CARINA VERIFICAR	190.00	1007	f	t	2026-07-24 14:19:44.077972+00
619	DEPO-00619	52119-1E500	52119-1E500	\N	50	Parachoque COROLLA 98 SALOM	350.00	1193	f	t	2026-07-24 14:19:44.077972+00
620	DEPO-00620	71711-85D30	71711-85D30	\N	50	Parachoque DEL GRAN VITARA 99 SZ04050BA	1200.00	609	f	t	2026-07-24 14:19:44.077972+00
621	DEPO-00621	52103-89110	52103-89110	\N	50	Parachoque DEL HILUX 93 METALICO 212-1638	400.00	598	f	t	2026-07-24 14:19:44.077972+00
622	DEPO-00622	PD-IO	PD-IO	\N	50	Parachoque DEL MITSUBISHI IO	700.00	599	f	t	2026-07-24 14:19:44.077972+00
623	DEPO-00623	6202238N00	6202238N00	\N	50	Parachoque DEL NISSAN CUSTOM NA20 ( BLANCO / PLOMO)	625.00	596	f	t	2026-07-24 14:19:44.077972+00
624	DEPO-00624	62022-0M001	62022-0M001	\N	50	Parachoque DEL NISSAN SUNNY B14 ( VERDE / BLANCO )	175.00	589	f	t	2026-07-24 14:19:44.077972+00
625	DEPO-00625	PD-JUNIOR	PD-JUNIOR	\N	50	Parachoque DEL PAJERO JUNIOR	700.00	601	f	t	2026-07-24 14:19:44.077972+00
626	DEPO-00626	PD-STARLET92	PD-STARLET92	\N	50	Parachoque DEL STARLET PLOMO CON Alogeno	700.00	605	f	t	2026-07-24 14:19:44.077972+00
627	DEPO-00627	SZ04011BA	SZ04011BA	\N	50	Parachoque DEL SUZUKI VITARA ESCUDO ( 3 PuertaS ) TYG	189.00	870	f	t	2026-07-24 14:19:44.077972+00
628	DEPO-00628	52119-21020	52119-21020	\N	50	Parachoque DEL TOYOTA CALDINA GT / CON Alogeno	700.00	591	f	t	2026-07-24 14:19:44.077972+00
629	DEPO-00629	T10-TS0P	T10-TS0P	\N	50	Parachoque DEL TOYOTA LEVIN 96	350.00	600	f	t	2026-07-24 14:19:44.077972+00
630	DEPO-00630	52119-16280	52119-16280	\N	50	Parachoque DELANTERO CORSA	350.00	1003	f	t	2026-07-24 14:19:44.077972+00
631	DEPO-00631	GG119-00010	GG119-00010	\N	50	Parachoque SUBARU FORESTER DELANTERO	1000.00	1108	f	t	2026-07-24 14:19:44.077972+00
632	DEPO-00632	PT-CALDINA	PT-CALDINA	\N	50	Parachoque TRAS CON SPOILER TOYOTA CALDINA GT	350.00	592	f	t	2026-07-24 14:19:44.077972+00
633	DEPO-00633	PT-STARLET92	PT-STARLET92	\N	50	Parachoque TRAS EP82 GT	350.00	604	f	t	2026-07-24 14:19:44.077972+00
634	DEPO-00634	PT-FORESTER	PT-FORESTER	\N	50	Parachoque TRAS FORESTER 97	100.00	606	f	t	2026-07-24 14:19:44.077972+00
635	DEPO-00635	50221	50221	\N	50	Parachoque TRAS MAZDA BONGO	350.00	590	f	t	2026-07-24 14:19:44.077972+00
636	DEPO-00636	PT-JUNIOR	PT-JUNIOR	\N	50	Parachoque TRAS MITSUBISHI JUNIOR	350.00	602	f	t	2026-07-24 14:19:44.077972+00
637	DEPO-00637	PT-E25	PT-E25	\N	50	Parachoque TRAS NISSAN CARAVAN K20 CHANCHO	350.00	594	f	t	2026-07-24 14:19:44.077972+00
638	DEPO-00638	PT-AE91	PT-AE91	\N	50	Parachoque TRAS TOYOTA COROLLA 90 SEDAN	400.00	595	f	t	2026-07-24 14:19:44.077972+00
639	DEPO-00639	PT-EVO6-F	PT-EVO6-F	\N	50	Parachoque TRASERO EVO 6 FIBRA	800.00	603	f	t	2026-07-24 14:19:44.077972+00
640	DEPO-00640	PT-FORESTER2000	PT-FORESTER2000	\N	50	Parachoque TRASERO FORESTER 2000	1000.00	1005	f	t	2026-07-24 14:19:44.077972+00
641	DEPO-00641	PT-SURF96	PT-SURF96	\N	50	Parachoque TRASERO SURF 96 3 PIEZAS	700.00	1002	f	t	2026-07-24 14:19:44.077972+00
642	DEPO-00642	PD-SURF96	PD-SURF96	\N	50	Parachoque DEL SURF HILUX METALICO 96 TY40165	700.00	607	f	t	2026-07-24 14:19:44.077972+00
643	DEPO-00643	PD-ESCUDO	PD-ESCUDO	\N	50	Parachoque DEL SUZUKI VITARA ESCUDO FIBRA	700.00	608	f	t	2026-07-24 14:19:44.077972+00
644	DEPO-00644	C-3072014	C-3072014	\N	51	Pastilla DE FRENO NAKHATAM SUABRU STI	60.00	167	f	t	2026-07-24 14:19:44.077972+00
645	DEPO-00645	C-3072001	C-3072001	\N	51	Pastilla DE SUBARU FRENO	47.90	166	f	t	2026-07-24 14:19:44.077972+00
646	DEPO-00646	860024	860024	\N	52	Perno barra estabilizador Turinng Mod. 97~98~99~ Largo TERRANO	23.00	1159	f	t	2026-07-24 14:19:44.077972+00
647	DEPO-00647	C-3024086	C-3024086	\N	30	Filtro de ACEITE 15601-33020 -TH2825 - PH2825	8.50	1094	f	t	2026-07-24 14:19:44.077972+00
648	DEPO-00648	PIS-VAR	PIS-VAR	\N	53	PISADERA DE SUBARU FORESTER VARIOS	200.00	922	f	t	2026-07-24 14:19:44.077972+00
649	DEPO-00649	75831-20320	75831-20320	\N	54	Porta placa CELICA 90-93	200.00	1015	f	t	2026-07-24 14:19:44.077972+00
650	DEPO-00650	MR-275638	MR-275638	\N	54	Porta placa CHARIOT GRANDIS	200.00	611	f	t	2026-07-24 14:19:44.077972+00
651	DEPO-00651	76801-35030	76801-35030	\N	54	Porta placa DE Maletera SURF	250.00	613	f	t	2026-07-24 14:19:44.077972+00
652	DEPO-00652	FJC506	FJC506	\N	55	Prensa Subaru DOMINGO	350.00	1204	f	t	2026-07-24 14:19:44.077972+00
653	DEPO-00653	PU-FORESTER-D-R	PU-FORESTER-D	R	56	Puerta SUBARU FORESTER ( Delantero Derecho )	100.00	620	f	t	2026-07-24 14:19:44.077972+00
654	DEPO-00654	PU-FORESTER-T-L	PU-FORESTER-T	L	56	Puerta SUBARU FORESTER ( Trasero Isquierdo )	100.00	621	f	t	2026-07-24 14:19:44.077972+00
655	DEPO-00655	PU-FORESTER-T-R	PU-FORESTER-T	R	56	Puerta SUBARU FORESTER ( Trasero Derecho )	100.00	622	f	t	2026-07-24 14:19:44.077972+00
656	DEPO-00656	PU-EVO6-D-L	PU-EVO6-D	L	56	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Delantero Isquierdo )	600.00	616	f	t	2026-07-24 14:19:44.077972+00
657	DEPO-00657	PU-EVO6-D-R	PU-EVO6-D	R	56	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Delantero Derecho )	600.00	617	f	t	2026-07-24 14:19:44.077972+00
658	DEPO-00658	PU-EVO6-T-L	PU-EVO6-T	L	56	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Trasero Isquierdo )	600.00	618	f	t	2026-07-24 14:19:44.077972+00
659	DEPO-00659	PU-EVO6-T-R	PU-EVO6-T	R	56	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Trasero Derecho )	600.00	619	f	t	2026-07-24 14:19:44.077972+00
660	DEPO-00660	PU-GVITARA-D-L	PU-GVITARA-D	L	56	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Delantero Isquierdo )	600.00	623	f	t	2026-07-24 14:19:44.077972+00
661	DEPO-00661	PU-GVITARA-D-R	PU-GVITARA-D	R	56	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Delantero Derecho )	600.00	624	f	t	2026-07-24 14:19:44.077972+00
662	DEPO-00662	PU-GVITARA-T-L	PU-GVITARA-T	L	56	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Trasero Isquierdo )	600.00	625	f	t	2026-07-24 14:19:44.077972+00
663	DEPO-00663	PU-GVITARA-T-R	PU-GVITARA-T	R	56	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Trasero Derecho )	600.00	626	f	t	2026-07-24 14:19:44.077972+00
664	DEPO-00664	PU-IPSUM-D-L	PU-IPSUM-D	L	56	Puerta TOYOTA IPSUM ( Delantero Isquierdo )	400.00	627	f	t	2026-07-24 14:19:44.077972+00
665	DEPO-00665	870005-G	870005-G	\N	4	Amortiguador TRASERO CALDINA 4X4 TURING ®	125.00	1189	f	t	2026-07-24 14:19:44.077972+00
666	DEPO-00666	870006-G	870006-G	\N	4	Amortiguador TRASERO CALDINA 4X4 TURING L{	125.00	1190	f	t	2026-07-24 14:19:44.077972+00
667	DEPO-00667	RAD-JUNIOR	RAD-JUNIOR	\N	57	Radiador MITSUBISHI JUNIOR	100.00	632	f	t	2026-07-24 14:19:44.077972+00
668	DEPO-00668	21410-VW300	21410-VW300	\N	57	Radiador NISSAN URVAN 01-06 E25	500.00	1177	f	t	2026-07-24 14:19:44.077972+00
669	DEPO-00669	RAD-CALDINAGT	RAD-CALDINAGT	\N	57	Radiador TOYOTA GT CALDINA	100.00	635	f	t	2026-07-24 14:19:44.077972+00
670	DEPO-00670	333-1425-R	333-1425	R	36	Guiñador JEEP RENEGADE Mod. 2015~2016~2017~2018~2019~2020~ F/SML	1.00	949	f	t	2026-07-24 14:19:44.077972+00
671	DEPO-00671	5646-L	5646	L	26	Espejo COROLLA AE 100 6 PINES	100.00	1127	f	t	2026-07-24 14:19:44.077972+00
672	DEPO-00672	5646-R	5646	R	26	Espejo COROLLA AE 100 6 PINES	100.00	1128	f	t	2026-07-24 14:19:44.077972+00
673	DEPO-00673	6207C3	6207C3	\N	60	RODAMIENTO Motor F12	75.00	1095	f	t	2026-07-24 14:19:44.077972+00
674	DEPO-00674	PJ18	PJ18	\N	60	RODAMIENTO SUBARU	75.00	1096	f	t	2026-07-24 14:19:44.077972+00
675	DEPO-00675	47-59-R	47-59	R	64	Stop BLUBIRT 96	100.00	710	f	t	2026-07-24 14:19:44.077972+00
676	DEPO-00676	20-199-L	20-199	L	64	Stop CORONA 90	100.00	780	f	t	2026-07-24 14:19:44.077972+00
677	DEPO-00677	20-199-R	20-199	R	64	Stop CORONA 90	100.00	781	f	t	2026-07-24 14:19:44.077972+00
678	DEPO-00678	20-179-L	20-179	L	64	Stop CORONA 90 2 COLORES	100.00	786	f	t	2026-07-24 14:19:44.077972+00
679	DEPO-00679	20-179-R	20-179	R	64	Stop CORONA 90 2 COLORES	100.00	787	f	t	2026-07-24 14:19:44.077972+00
680	DEPO-00680	20-139-L	20-139	L	64	Stop CORONA 90 3 COLORES	100.00	782	f	t	2026-07-24 14:19:44.077972+00
681	DEPO-00681	20-139-R	20-139	R	64	Stop CORONA 90 3 COLORES	100.00	783	f	t	2026-07-24 14:19:44.077972+00
682	DEPO-00682	220-63436-R	220-63436	R	64	Stop NISSAN PHATFINDER	250.00	726	f	t	2026-07-24 14:19:44.077972+00
683	DEPO-00683	SCOOTER	SCOOTER	\N	62	SCOOTER	3500.00	866	f	t	2026-07-24 14:19:44.077972+00
684	DEPO-00684	SCOOTER-CA	SCOOTER-CA	\N	62	SCOOTER CASCO	500.00	867	f	t	2026-07-24 14:19:44.077972+00
685	DEPO-00685	E-VAR-L	E-VAR	L	26	Espejo VARIOS ( Isquierdo )	25.00	329	f	t	2026-07-24 14:19:44.077972+00
686	DEPO-00686	E-VAR-R	E-VAR	R	26	Espejo VARIOS ( Derecho )	25.00	330	f	t	2026-07-24 14:19:44.077972+00
687	DEPO-00687	220-24765-L	220-24765	L	64	Stop AD 2006 215-194305	70.00	686	f	t	2026-07-24 14:19:44.077972+00
688	DEPO-00688	4287-L	4287	L	64	Stop ATLAS 215-1915	100.00	1026	f	t	2026-07-24 14:19:44.077972+00
689	DEPO-00689	4287-R	4287	R	64	Stop ATLAS 215-1915	100.00	1027	f	t	2026-07-24 14:19:44.077972+00
690	DEPO-00690	220-51616-L	220-51616	L	64	Stop ATRAIL	100.00	638	f	t	2026-07-24 14:19:44.077972+00
691	DEPO-00691	220-51616-R	220-51616	R	64	Stop ATRAIL	100.00	639	f	t	2026-07-24 14:19:44.077972+00
692	DEPO-00692	4294-L	4294	L	64	Stop B11 CORTO	75.00	691	f	t	2026-07-24 14:19:44.077972+00
693	DEPO-00693	1059-L	1059	L	64	Stop B14 NISSAN	75.00	703	f	t	2026-07-24 14:19:44.077972+00
694	DEPO-00694	1059-R	1059	R	64	Stop B14 NISSAN	75.00	704	f	t	2026-07-24 14:19:44.077972+00
695	DEPO-00695	220-61871-R	220-61871	R	64	Stop BONGO	100.00	660	f	t	2026-07-24 14:19:44.077972+00
696	DEPO-00696	J21-L	J21	L	64	Stop BOXY	200.00	749	f	t	2026-07-24 14:19:44.077972+00
697	DEPO-00697	J21-R	J21	R	64	Stop BOXY	200.00	750	f	t	2026-07-24 14:19:44.077972+00
698	DEPO-00698	7352-R	7352	R	64	Stop CALDINA A MUELLE	100.00	752	f	t	2026-07-24 14:19:44.077972+00
699	DEPO-00699	1231-L	1231	L	64	Stop CALDINA GT	100.00	756	f	t	2026-07-24 14:19:44.077972+00
700	DEPO-00700	1231-R	1231	R	64	Stop CALDINA GT	100.00	757	f	t	2026-07-24 14:19:44.077972+00
701	DEPO-00701	7409-L	7409	L	64	Stop CALDINA TURING	100.00	753	f	t	2026-07-24 14:19:44.077972+00
702	DEPO-00702	7409-R	7409	R	64	Stop CALDINA TURING	100.00	754	f	t	2026-07-24 14:19:44.077972+00
703	DEPO-00703	7157-L	7157	L	64	Stop CARIB 80	100.00	758	f	t	2026-07-24 14:19:44.077972+00
704	DEPO-00704	12-263-L	12-263	L	64	Stop CARIB 90	100.00	760	f	t	2026-07-24 14:19:44.077972+00
705	DEPO-00705	12-263-R	12-263	R	64	Stop CARIB 90	100.00	761	f	t	2026-07-24 14:19:44.077972+00
706	DEPO-00706	13-55-L	13-55	L	64	Stop CARIB BZ	200.00	766	f	t	2026-07-24 14:19:44.077972+00
707	DEPO-00707	13-55-R	13-55	R	64	Stop CARIB BZ	200.00	767	f	t	2026-07-24 14:19:44.077972+00
708	DEPO-00708	20-274-L	20-274	L	64	Stop CARINA	70.00	768	f	t	2026-07-24 14:19:44.077972+00
709	DEPO-00709	20-274-R	20-274	R	64	Stop CARINA	70.00	769	f	t	2026-07-24 14:19:44.077972+00
710	DEPO-00710	53-07901-L	53-07901	L	64	Stop CARINA92	70.00	764	f	t	2026-07-24 14:19:44.077972+00
711	DEPO-00711	53-07901-R	53-07901	R	64	Stop CARINA92	70.00	765	f	t	2026-07-24 14:19:44.077972+00
712	DEPO-00712	33-09303-R	33-09303	R	64	Stop CELICA 90	250.00	773	f	t	2026-07-24 14:19:44.077972+00
713	DEPO-00713	20-334-L	20-334	L	64	Stop CELICA 99	100.00	776	f	t	2026-07-24 14:19:44.077972+00
714	DEPO-00714	20-334-R	20-334	R	64	Stop CELICA 99	100.00	777	f	t	2026-07-24 14:19:44.077972+00
715	DEPO-00715	4022-L	4022	L	64	Stop CHANCHO CARAVAN	200.00	711	f	t	2026-07-24 14:19:44.077972+00
716	DEPO-00716	4022-R	4022	R	64	Stop CHANCHO CARAVAN	200.00	712	f	t	2026-07-24 14:19:44.077972+00
717	DEPO-00717	043-1566-L	043-1566	L	64	Stop COLT MITSUBISHI	70.00	1030	f	t	2026-07-24 14:19:44.077972+00
718	DEPO-00718	043-1566-R	043-1566	R	64	Stop COLT MITSUBISHI	70.00	1031	f	t	2026-07-24 14:19:44.077972+00
719	DEPO-00719	16-115-L	16-115	L	64	Stop COROLLA 2	100.00	794	f	t	2026-07-24 14:19:44.077972+00
720	DEPO-00720	16-115-R	16-115	R	64	Stop COROLLA 2	100.00	795	f	t	2026-07-24 14:19:44.077972+00
721	DEPO-00721	12-104-L	12-104	L	64	Stop COROLLA 78	70.00	790	f	t	2026-07-24 14:19:44.077972+00
722	DEPO-00722	12-173-R	12-173	R	64	Stop COROLLA 83 212-1915	70.00	784	f	t	2026-07-24 14:19:44.077972+00
723	DEPO-00723	13-29-R	13-29	R	64	Stop COROLLA 89	70.00	785	f	t	2026-07-24 14:19:44.077972+00
724	DEPO-00724	12-327-R	12-327	R	64	Stop COROLLA 90 212-1954	70.00	799	f	t	2026-07-24 14:19:44.077972+00
725	DEPO-00725	33-09307-L	33-09307	L	64	Stop COROLLA 92 212-1967	70.00	788	f	t	2026-07-24 14:19:44.077972+00
726	DEPO-00726	33-09307-R	33-09307	R	64	Stop COROLLA 92 212-1967	70.00	789	f	t	2026-07-24 14:19:44.077972+00
727	DEPO-00727	12-127-L	12-127	L	64	Stop COROLLA KE70	\N	1032	f	t	2026-07-24 14:19:44.077972+00
728	DEPO-00728	12-127-R	12-127	R	64	Stop COROLLA KE70	70.00	1033	f	t	2026-07-24 14:19:44.077972+00
729	DEPO-00729	12-150-L	12-150	L	64	Stop COROLLA KE75 212-1913	70.00	1034	f	t	2026-07-24 14:19:44.077972+00
730	DEPO-00730	212-1967-R	212-1967	R	64	Stop COROLLA Mod. 92-94 Auto	70.00	1037	f	t	2026-07-24 14:19:44.077972+00
731	DEPO-00731	16-98-L	16-98	L	64	Stop COROLLA2	100.00	1022	f	t	2026-07-24 14:19:44.077972+00
732	DEPO-00732	16-98-R	16-98	R	64	Stop COROLLA2	100.00	1023	f	t	2026-07-24 14:19:44.077972+00
733	DEPO-00733	10-120-L	10-120	L	64	Stop CORONA 1 COLOR	100.00	778	f	t	2026-07-24 14:19:44.077972+00
734	DEPO-00734	33-1105-L	33-1105	L	64	Stop CORONA 99 rojo y blanco	70.00	1017	f	t	2026-07-24 14:19:44.077972+00
735	DEPO-00735	33-1105-R	33-1105	R	64	Stop CORONA 99	70.00	1018	f	t	2026-07-24 14:19:44.077972+00
736	DEPO-00736	53-12003-L	53-12003	L	64	Stop CORSA	70.00	806	f	t	2026-07-24 14:19:44.077972+00
737	DEPO-00737	53-12003-R	53-12003	R	64	Stop CORSA	70.00	807	f	t	2026-07-24 14:19:44.077972+00
738	DEPO-00738	220-51328-R	220-51328	R	64	Stop DAIHATSU 95	100.00	640	f	t	2026-07-24 14:19:44.077972+00
739	DEPO-00739	4188-L	4188	L	64	Stop DATSUN B310 1979	70.00	707	f	t	2026-07-24 14:19:44.077972+00
740	DEPO-00740	4188-R	4188	R	64	Stop DATSUN B310 1979	\N	708	f	t	2026-07-24 14:19:44.077972+00
741	DEPO-00741	7110-L	7110	L	64	Stop DATSUN B310 1979	70.00	705	f	t	2026-07-24 14:19:44.077972+00
742	DEPO-00742	7110-R	7110	R	64	Stop DATSUN B310 1979	70.00	706	f	t	2026-07-24 14:19:44.077972+00
743	DEPO-00743	1053-L	1053	L	64	Stop DE LEGACY	100.00	743	f	t	2026-07-24 14:19:44.077972+00
744	DEPO-00744	1053-R	1053	R	64	Stop DE LEGACY	100.00	743	f	t	2026-07-24 14:19:44.077972+00
745	DEPO-00745	334-1906-L	334-1906	L	64	Stop DODGE RAM 1500 2500 PICK UP Mod.2002~2003~2004~2005~2006	440.00	127	f	t	2026-07-24 14:19:44.077972+00
746	DEPO-00746	334-1906-R	334-1906	R	64	Stop DODGE RAM 1500 2500 PICK UP Mod.2002~2003~2004~2005~2006	440.00	128	f	t	2026-07-24 14:19:44.077972+00
747	DEPO-00747	231-1955-L	231-1955	L	64	Stop Ford RANGER Mod. 2008~2009~2010~2011	392.00	107	f	t	2026-07-24 14:19:44.077972+00
748	DEPO-00748	220-20697-L	220-20697	L	64	Stop FORESTER2000	250.00	739	f	t	2026-07-24 14:19:44.077972+00
749	DEPO-00749	220-20697-R	220-20697	R	64	Stop FORESTER2000	250.00	740	f	t	2026-07-24 14:19:44.077972+00
750	DEPO-00750	795-R	795	R	64	Stop FX	70.00	818	f	t	2026-07-24 14:19:44.077972+00
751	DEPO-00751	26-55-L	26-55	L	64	Stop GRAND VIA 212-19B3	100.00	1039	f	t	2026-07-24 14:19:44.077972+00
752	DEPO-00752	26-55-R	26-55	R	64	Stop GRAND VIA 212-19B3	100.00	1040	f	t	2026-07-24 14:19:44.077972+00
753	DEPO-00753	26-15-L	26-15	L	64	Stop HIACE CUADRADO	70.00	824	f	t	2026-07-24 14:19:44.077972+00
754	DEPO-00754	212-1916-R	212-1916	R	64	Stop HIACE Mod 84/87	25.00	54	f	t	2026-07-24 14:19:44.077972+00
755	DEPO-00755	33-07803-L	33-07803	L	64	Stop HILUX SUF 96	200.00	828	f	t	2026-07-24 14:19:44.077972+00
756	DEPO-00756	33-07803-R	33-07803	R	64	Stop HILUX SUF 96	100.00	829	f	t	2026-07-24 14:19:44.077972+00
757	DEPO-00757	1167-L	1167	L	64	Stop HONDA CRV	100.00	643	f	t	2026-07-24 14:19:44.077972+00
758	DEPO-00758	1167-R	1167	R	64	Stop HONDA CRV	100.00	644	f	t	2026-07-24 14:19:44.077972+00
759	DEPO-00759	MB952979-L	MB952979	L	64	STOP MITSUBISHI CARISMA 97-99	100.00	645	f	t	2026-07-24 14:19:44.077972+00
760	DEPO-00760	MB952979-R	MB952979	R	64	STOP MITSUBISHI CARISMA 97-99	100.00	646	f	t	2026-07-24 14:19:44.077972+00
761	DEPO-00761	01405-L	01405	L	64	Stop HONDA EG	100.00	647	f	t	2026-07-24 14:19:44.077972+00
762	DEPO-00762	01405-R	01405	R	64	Stop HONDA EG	100.00	648	f	t	2026-07-24 14:19:44.077972+00
763	DEPO-00763	043-1262-L	043-1262	L	64	Stop HONDA EK	100.00	651	f	t	2026-07-24 14:19:44.077972+00
764	DEPO-00764	043-1262-R	043-1262	R	64	Stop HONDA EK	100.00	652	f	t	2026-07-24 14:19:44.077972+00
765	DEPO-00765	043-1212-L	043-1212	L	64	Stop HONDA VARIOS	70.00	1024	f	t	2026-07-24 14:19:44.077972+00
766	DEPO-00766	043-1212-R	043-1212	R	64	Stop HONDA VARIOS	70.00	1025	f	t	2026-07-24 14:19:44.077972+00
767	DEPO-00767	220-20553-L	220-20553	L	64	Stop IMPREZA	300.00	741	f	t	2026-07-24 14:19:44.077972+00
768	DEPO-00768	220-20553-R	220-20553	R	64	Stop IMPREZA	300.00	742	f	t	2026-07-24 14:19:44.077972+00
769	DEPO-00769	220-22185-R	220-22185	R	64	Stop INTEGRA HONDA	100.00	654	f	t	2026-07-24 14:19:44.077972+00
770	DEPO-00770	220-22220-L	220-22220	L	64	Stop INTEGRA HONDA	100.00	653	f	t	2026-07-24 14:19:44.077972+00
771	DEPO-00771	1311-L	1311	L	64	Stop IO	100.00	1036	f	t	2026-07-24 14:19:44.077972+00
772	DEPO-00772	1311-R	1311	R	64	Stop IO	50.00	1035	f	t	2026-07-24 14:19:44.077972+00
773	DEPO-00773	44-5-R	44-5	R	64	Stop IPSUM	100.00	1113	f	t	2026-07-24 14:19:44.077972+00
774	DEPO-00774	212-1904-L	212-1904	L	64	Stop LAND CRUISSER DINA Mod.74~81 UNIVERSAL	32.00	51	f	t	2026-07-24 14:19:44.077972+00
775	DEPO-00775	212-1904-R	212-1904	R	64	Stop LAND CRUISSER DINA Mod.74~81 UNIVERSAL	32.00	52	f	t	2026-07-24 14:19:44.077972+00
776	DEPO-00776	12-426-L	12-426	L	64	Stop LEVIN AE 92	100.00	834	f	t	2026-07-24 14:19:44.077972+00
777	DEPO-00777	7337-L	7337	L	64	Stop LEVIN TOYOTA LEVIN 90	100.00	830	f	t	2026-07-24 14:19:44.077972+00
778	DEPO-00778	7337-R	7337	R	64	Stop LEVIN TOYOTA LEVIN 90	100.00	831	f	t	2026-07-24 14:19:44.077972+00
779	DEPO-00779	7370-L	7370	L	64	Stop LEVN 92	100.00	832	f	t	2026-07-24 14:19:44.077972+00
780	DEPO-00780	7370-R	7370	R	64	Stop LEVN 92	100.00	833	f	t	2026-07-24 14:19:44.077972+00
781	DEPO-00781	28-97-L	28-97	L	64	Stop LITE ACE 212-1983	100.00	838	f	t	2026-07-24 14:19:44.077972+00
782	DEPO-00782	28-97-R	28-97	R	64	Stop LITE ACE 212-1983	100.00	839	f	t	2026-07-24 14:19:44.077972+00
783	DEPO-00783	4886-L	4886	L	64	Stop MARCH	100.00	840	f	t	2026-07-24 14:19:44.077972+00
784	DEPO-00784	4886-R	4886	R	64	Stop MARCH	100.00	841	f	t	2026-07-24 14:19:44.077972+00
785	DEPO-00785	216-1992-L	216-1992	L	64	Stop Mazda BT-50 Mod.2012~2014 Pick Up Camioneta	326.00	71	f	t	2026-07-24 14:19:44.077972+00
786	DEPO-00786	216-1992-R	216-1992	R	64	Stop Mazda BT-50 Mod.2012~2014 Pick Up Camioneta	326.00	72	f	t	2026-07-24 14:19:44.077972+00
787	DEPO-00787	216-19AG-L	216-19AG	L	64	Stop MAZDA BT-50 Mod.2015~2016~2017~2018~2019~2020	610.00	73	f	t	2026-07-24 14:19:44.077972+00
788	DEPO-00788	216-19AG-R	216-19AG	R	64	Stop MAZDA BT-50 Mod.2015~2016~2017~2018~2019~2020	610.00	74	f	t	2026-07-24 14:19:44.077972+00
789	DEPO-00789	31-11301-L	31-11301	L	64	Stop MITSUBISHI CHARIOT GRANDIS	200.00	679	f	t	2026-07-24 14:19:44.077972+00
790	DEPO-00790	31-11301-R	31-11301	R	64	Stop MITSUBISHI CHARIOT GRANDIS	200.00	680	f	t	2026-07-24 14:19:44.077972+00
791	DEPO-00791	043-8557-L	043-8557	L	64	Stop MITSUBISHI COULT 3 1989	100.00	661	f	t	2026-07-24 14:19:44.077972+00
792	DEPO-00792	043-8557-R	043-8557	R	64	Stop MITSUBISHI COULT 3 1989	100.00	662	f	t	2026-07-24 14:19:44.077972+00
793	DEPO-00793	043-1593-L	043-1593	L	64	Stop MITSUBISHI GALANT	100.00	681	f	t	2026-07-24 14:19:44.077972+00
794	DEPO-00794	1121-R	1121	R	64	Stop MITSUBISHI JUNIOR	200.00	668	f	t	2026-07-24 14:19:44.077972+00
795	DEPO-00795	214-1941-L	214-1941	L	64	Stop Mitsubishi LANCER Mod. 92~93~94~95~96 LIBERO	164.00	1112	f	t	2026-07-24 14:19:44.077972+00
796	DEPO-00796	220-37508-L	220-37508	L	64	Stop MITSUBSHI DELICA	100.00	663	f	t	2026-07-24 14:19:44.077972+00
797	DEPO-00797	220-37508-R	220-37508	R	64	Stop MITSUBSHI DELICA	100.00	664	f	t	2026-07-24 14:19:44.077972+00
798	DEPO-00798	043-6772-L	043-6772	L	64	Stop MONTERO 214-1922	70.00	1114	f	t	2026-07-24 14:19:44.077972+00
799	DEPO-00799	043-6772-R	043-6772	R	64	Stop MONTERO 214-1922	70.00	1115	f	t	2026-07-24 14:19:44.077972+00
800	DEPO-00800	220-24522-L	220-24522	L	64	Stop NA 20 URVAN 215-1942	100.00	723	f	t	2026-07-24 14:19:44.077972+00
801	DEPO-00801	220-24522-R	220-24522	R	64	Stop NA 20 URVAN 215-1942	100.00	724	f	t	2026-07-24 14:19:44.077972+00
802	DEPO-00802	7309-R	7309	R	64	Stop NISSAN AD WAGON	70.00	1046	f	t	2026-07-24 14:19:44.077972+00
803	DEPO-00803	220-24555-L	220-24555	L	64	Stop NISSAN AD Y10	70.00	687	f	t	2026-07-24 14:19:44.077972+00
804	DEPO-00804	220-24555-R	220-24555	R	64	Stop NISSAN AD Y10	70.00	688	f	t	2026-07-24 14:19:44.077972+00
805	DEPO-00805	4339-R	4339	R	64	Stop NISSAN B11 LARGO	70.00	695	f	t	2026-07-24 14:19:44.077972+00
806	DEPO-00806	33-10505-L	33-10505	L	64	Stop NISSAN CUSTOM E 24	100.00	715	f	t	2026-07-24 14:19:44.077972+00
807	DEPO-00807	33-10505-R	33-10505	R	64	Stop NISSAN CUSTOM E 24	100.00	716	f	t	2026-07-24 14:19:44.077972+00
808	DEPO-00808	7327-L	7327	L	64	Stop NISSAN MARCH 97 a rayas	100.00	721	f	t	2026-07-24 14:19:44.077972+00
809	DEPO-00809	7327-R	7327	R	64	Stop NISSAN MARCH 97 a rayas	100.00	722	f	t	2026-07-24 14:19:44.077972+00
810	DEPO-00810	7379-L	7379	L	64	Stop NISSAN PULSAR	70.00	1028	f	t	2026-07-24 14:19:44.077972+00
811	DEPO-00811	7379-R	7379	R	64	Stop NISSAN PULSAR	70.00	1029	f	t	2026-07-24 14:19:44.077972+00
812	DEPO-00812	220-52458-L	220-52458	L	64	Stop NISSAN SERENA	70.00	729	f	t	2026-07-24 14:19:44.077972+00
813	DEPO-00813	220-52458-R	220-52458	R	64	Stop NISSAN SERENA	70.00	730	f	t	2026-07-24 14:19:44.077972+00
814	DEPO-00814	4363-L	4363	L	64	Stop NISSAN SUNNY B12	70.00	697	f	t	2026-07-24 14:19:44.077972+00
815	DEPO-00815	4363-R	4363	R	64	Stop NISSAN SUNNY B12	70.00	698	f	t	2026-07-24 14:19:44.077972+00
816	DEPO-00816	7344-L	7344	L	64	Stop NISSAN SUNNY B13 DOBLE LINEA 215-1991	70.00	699	f	t	2026-07-24 14:19:44.077972+00
817	DEPO-00817	7344-R	7344	R	64	Stop NISSAN SUNNY B13 DOBLE LINEA 215-1991	70.00	700	f	t	2026-07-24 14:19:44.077972+00
818	DEPO-00818	215-1942-R	215-1942	R	64	Stop Nissan URVAN Mod.90~ E24 Minibus E2	79.00	950	f	t	2026-07-24 14:19:44.077972+00
819	DEPO-00819	043-1150-L	043-1150	L	64	Stop PRELUDE	\N	655	f	t	2026-07-24 14:19:44.077972+00
820	DEPO-00820	043-1150-R	043-1150	R	64	Stop PRELUDE	100.00	656	f	t	2026-07-24 14:19:44.077972+00
821	DEPO-00821	7307-L	7307	L	64	Stop PRESSEA	70.00	727	f	t	2026-07-24 14:19:44.077972+00
822	DEPO-00822	7307-R	7307	R	64	Stop PRESSEA	70.00	728	f	t	2026-07-24 14:19:44.077972+00
823	DEPO-00823	10-85-R	10-85	R	64	Stop REFLEX	70.00	1021	f	t	2026-07-24 14:19:44.077972+00
824	DEPO-00824	551-19A2-R	551-19A2	R	64	Stop Renault SANDERO STEPWAY Mod. 2012~2013~2014~2015	600.00	943	f	t	2026-07-24 14:19:44.077972+00
825	DEPO-00825	043-1536-L	043-1536	L	64	Stop RVR 92	100.00	677	f	t	2026-07-24 14:19:44.077972+00
826	DEPO-00826	043-1536-R	043-1536	R	64	Stop RVR 92	100.00	678	f	t	2026-07-24 14:19:44.077972+00
827	DEPO-00827	043-1550-L	043-1550	L	64	Stop RVR BI COLOR	70.00	673	f	t	2026-07-24 14:19:44.077972+00
828	DEPO-00828	043-1550-R	043-1550	R	64	Stop RVR BI COLOR	70.00	674	f	t	2026-07-24 14:19:44.077972+00
829	DEPO-00829	33-1300-R	33-1300	R	64	Stop SOLEI EP82	70.00	817	f	t	2026-07-24 14:19:44.077972+00
830	DEPO-00830	33-1300-L	33-1300	L	64	Stop SOLEI EP82	70.00	816	f	t	2026-07-24 14:19:44.077972+00
831	DEPO-00831	12-353-R	12-353	R	64	Stop SPRINTER 93	70.00	1038	f	t	2026-07-24 14:19:44.077972+00
832	DEPO-00832	1079-L	1079	L	64	Stop STARLET	70.00	819	f	t	2026-07-24 14:19:44.077972+00
833	DEPO-00833	1079-R	1079	R	64	Stop STARLET	70.00	820	f	t	2026-07-24 14:19:44.077972+00
834	DEPO-00834	53-07601-L	53-07601	L	64	Stop STARLET EP82	70.00	821	f	t	2026-07-24 14:19:44.077972+00
835	DEPO-00835	53-07601-R	53-07601	R	64	Stop STARLET EP82	\N	822	f	t	2026-07-24 14:19:44.077972+00
836	DEPO-00836	220-75539-R	220-75539	R	64	Stop STARLET EP82 TURBO	70.00	823	f	t	2026-07-24 14:19:44.077972+00
837	DEPO-00837	4340-L	4340	L	64	Stop SUABU DOMINGO	150.00	737	f	t	2026-07-24 14:19:44.077972+00
838	DEPO-00838	4340-R	4340	R	64	Stop SUABU DOMINGO	150.00	738	f	t	2026-07-24 14:19:44.077972+00
839	DEPO-00839	220-20597-L	220-20597	L	64	Stop SUBARU 97	140.00	735	f	t	2026-07-24 14:19:44.077972+00
840	DEPO-00840	220-20597-R	220-20597	R	64	Stop SUBARU 97	140.00	736	f	t	2026-07-24 14:19:44.077972+00
841	DEPO-00841	2074-L	2074	L	64	Stop SUBARU DOMINGO	350.00	1041	f	t	2026-07-24 14:19:44.077972+00
842	DEPO-00842	2074-R	2074	R	64	Stop SUBARU DOMINGO	350.00	1042	f	t	2026-07-24 14:19:44.077972+00
843	DEPO-00843	220-20491-R	220-20491	R	64	Stop SUBARU LEGACY 92 VERIFICAR MOD	100.00	1047	f	t	2026-07-24 14:19:44.077972+00
844	DEPO-00844	836-L	836	L	64	Stop SUNNY B13 215-1967	70.00	701	f	t	2026-07-24 14:19:44.077972+00
845	DEPO-00845	836-R	836	R	64	Stop SUNNY B13 215-1967	70.00	702	f	t	2026-07-24 14:19:44.077972+00
846	DEPO-00846	218-1905-R	218-1905	R	64	Stop Suzuki SAMURAI	52.00	92	f	t	2026-07-24 14:19:44.077972+00
847	DEPO-00847	218-1974-R	218-1974	R	64	Stop Suzuqui ERTIGA Mod. 2011 2012~2013~2014	315.00	944	f	t	2026-07-24 14:19:44.077972+00
848	DEPO-00848	218-1949-L	218-1949	L	64	Stop Suzuqui GRAN VITARA Mod.2005 Cristal 2	422.00	93	f	t	2026-07-24 14:19:44.077972+00
849	DEPO-00849	218-1949-R	218-1949	R	64	Stop Suzuqui GRAN VITARA Mod.2005 Cristal 2	422.00	94	f	t	2026-07-24 14:19:44.077972+00
850	DEPO-00850	312-19C2-L	312-19C2	L	64	Stop Toyota 4RUNNER Mod. 2013~2014~2015~2016~2017. LED	1089.00	951	f	t	2026-07-24 14:19:44.077972+00
851	DEPO-00851	312-19C2-R	312-19C2	R	64	Stop Toyota 4RUNNER Mod. 2013~2014~2015~2016~2017. LED	1089.00	952	f	t	2026-07-24 14:19:44.077972+00
852	DEPO-00852	20-222-L	20-222	L	64	Stop TOYOTA CARINA 91	70.00	762	f	t	2026-07-24 14:19:44.077972+00
853	DEPO-00853	20-222-R	20-222	R	64	Stop TOYOTA CARINA 91	70.00	763	f	t	2026-07-24 14:19:44.077972+00
854	DEPO-00854	12-259-R	12-259	R	64	Stop TOYOTA COROLLA 212-1935-1	70.00	793	f	t	2026-07-24 14:19:44.077972+00
855	DEPO-00855	20-161-R	20-161	R	64	Stop TOYOTA CORONA con retro	70.00	803	f	t	2026-07-24 14:19:44.077972+00
856	DEPO-00856	33-09803-L	33-09803	L	64	Stop TOYOTA LEVIN	100.00	836	f	t	2026-07-24 14:19:44.077972+00
857	DEPO-00857	33-09803-R	33-09803	R	64	Stop TOYOTA LEVIN	100.00	837	f	t	2026-07-24 14:19:44.077972+00
858	DEPO-00858	33-13003-R	33-13003	R	64	Stop TOYOTA SINOS VERIFICAR	70.00	1045	f	t	2026-07-24 14:19:44.077972+00
859	DEPO-00859	212-19Y002-U-L	212-19Y002-U	L	64	Stop TOYOTA SUCCED 212-19Y002	200.00	846	f	t	2026-07-24 14:19:44.077972+00
860	DEPO-00860	212-19Y002-U-R	212-19Y002-U	R	64	Stop TOYOTA SUCCED 212-19Y002	200.00	847	f	t	2026-07-24 14:19:44.077972+00
861	DEPO-00861	33-12103-L	33-12103	L	64	Stop TOYOTA TERCEL	70.00	848	f	t	2026-07-24 14:19:44.077972+00
862	DEPO-00862	33-12103-R	33-12103	R	64	Stop TOYOTA TERCEL	70.00	849	f	t	2026-07-24 14:19:44.077972+00
863	DEPO-00863	32-128-L	32-128	L	64	Stop TOYOTA WINDOWN	70.00	860	f	t	2026-07-24 14:19:44.077972+00
864	DEPO-00864	32-128-R	32-128	R	64	Stop TOYOTA WINDOWN	70.00	861	f	t	2026-07-24 14:19:44.077972+00
865	DEPO-00865	12-319-R	12-319	R	64	Stop TRUENO 90	100.00	853	f	t	2026-07-24 14:19:44.077972+00
866	DEPO-00866	12-301-R	12-301	R	64	Stop TRUENO 90 AE92	100.00	851	f	t	2026-07-24 14:19:44.077972+00
867	DEPO-00867	220-76610-L	220-76610	L	64	Stop TRUENO 96	\N	854	f	t	2026-07-24 14:19:44.077972+00
868	DEPO-00868	220-76610-R	220-76610	R	64	Stop TRUENO 96	100.00	855	f	t	2026-07-24 14:19:44.077972+00
869	DEPO-00869	7324-L	7324	L	64	Stop VERIFICAR	1.00	1016	f	t	2026-07-24 14:19:44.077972+00
870	DEPO-00870	220-32224-R	220-32224	R	64	Stop VIATARA ESCUDO	70.00	746	f	t	2026-07-24 14:19:44.077972+00
871	DEPO-00871	220-32224-L	220-32224	L	64	Stop VITARA ESCUDO	70.00	745	f	t	2026-07-24 14:19:44.077972+00
872	DEPO-00872	218-1983-L	218-1983	L	64	Stop VITARA Mod. 2015~2016~2017	392.00	95	f	t	2026-07-24 14:19:44.077972+00
873	DEPO-00873	218-1983-R	218-1983	R	64	Stop VITARA Mod. 2015~2016~2017	392.00	96	f	t	2026-07-24 14:19:44.077972+00
874	DEPO-00874	52-049-R	52-049	R	64	Stop VITZ	70.00	865	f	t	2026-07-24 14:19:44.077972+00
875	DEPO-00875	441-19C5-L	441-19C5	L	64	Stop Volkswagen SAVEIRO Mod. 2010~2011~2013~2014~2015	257.00	131	f	t	2026-07-24 14:19:44.077972+00
876	DEPO-00876	441-19C5-R	441-19C5	R	64	Stop Volkswagen SAVEIRO Mod. 2010~2011~2013~2014~2015	257.00	132	f	t	2026-07-24 14:19:44.077972+00
877	DEPO-00877	043-1563-L	043-1563	L	65	Stop-LANCER 92 214-1942	100.00	670	f	t	2026-07-24 14:19:44.077972+00
878	DEPO-00878	DF12001	DF12001	\N	67	Tacometro	350.00	1198	f	t	2026-07-24 14:19:44.077972+00
879	DEPO-00879	TT-FORESTER-F	TT-FORESTER-F	\N	68	Tapa de TABLERO FORESTER 97-2000 FIBRA	70.00	928	f	t	2026-07-24 14:19:44.077972+00
880	DEPO-00880	SB11013A-L	SB11013A	L	69	Tapabarro FORESTER Mod. 98~99~2000~2001~2002	1000.00	1000	f	t	2026-07-24 14:19:44.077972+00
881	DEPO-00881	SB11013A-R	SB11013A	R	69	Tapabarro FORESTER Mod. 98~99~2000~2001~2002	1000.00	1001	f	t	2026-07-24 14:19:44.077972+00
882	DEPO-00882	3494-L	3494	L	71	TOYOTA EP82	70.00	289	f	t	2026-07-24 14:19:44.077972+00
883	DEPO-00883	3485-R	3485	R	71	TOYOTA	70.00	290	t	t	2026-07-24 14:19:44.077972+00
884	DEPO-00884	TD-04	TD-04	\N	72	TURBO TD04	300.00	935	f	t	2026-07-24 14:19:44.077972+00
885	DEPO-00885	4280-L	4280	L	73	VARIOS VERIFICAR	1.00	247	f	t	2026-07-24 14:19:44.077972+00
886	DEPO-00886	197001	197001	\N	74	Velocimetro SUBARU forester	100.00	936	f	t	2026-07-24 14:19:44.077972+00
887	DEPO-00887	22002	22002	\N	74	Velocimetro SUBARU impreza	100.00	938	f	t	2026-07-24 14:19:44.077972+00
888	DEPO-00888	257500-3532	257500-3532	\N	74	Velocimetro SUBARU lite ace	100.00	937	f	t	2026-07-24 14:19:44.077972+00
889	DEPO-00889	20-93-R	20-93	R	10	Bisel CORONA CON Media luz 212-1535	20.00	889	f	t	2026-07-24 14:19:44.077972+00
890	DEPO-00890	53130-95J08-R	53130-95J08	R	10	Bisel CUSTOM 90 CROMADO	50.00	883	f	t	2026-07-24 14:19:44.077972+00
891	DEPO-00891	53130-95J07-L	53130-95J07	L	10	Bisel CUSTOM 90 PLOMO	50.00	882	f	t	2026-07-24 14:19:44.077972+00
892	DEPO-00892	74071-60R00-L	74071-60R00	L	10	Bisel NISSAN AD	50.00	878	f	t	2026-07-24 14:19:44.077972+00
893	DEPO-00893	74071-60R00-R	74071-60R00	R	10	Bisel NISSAN AD	50.00	879	f	t	2026-07-24 14:19:44.077972+00
894	DEPO-00894	62411-L	62411	L	10	Bisel NISSAN URVAN	75.00	884	f	t	2026-07-24 14:19:44.077972+00
895	DEPO-00895	3686-N-L	3686-N	L	26	Espejo MITSUBISHI Montero Negro ELECTRICO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
896	DEPO-00896	3686-N-R	3686-N	R	26	Espejo MITSUBISHI Montero Negro ELECTRICO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
897	DEPO-00897	VZV-32-L	VZV-32	L	26	Espejo Toyota Camry 92	\N	\N	f	t	2026-07-24 14:19:44.077972+00
898	DEPO-00898	G-35-L	G-35	L	26	Espejo Toyota Varios	\N	\N	f	t	2026-07-24 14:19:44.077972+00
899	DEPO-00899	G-35-R	G-35	R	26	Espejo Toyota Varios	\N	\N	f	t	2026-07-24 14:19:44.077972+00
900	DEPO-00900	1517-L	1517	L	26	Espejo Honda varios	\N	\N	f	t	2026-07-24 14:19:44.077972+00
901	DEPO-00901	5483-2-R	5483-2	R	26	Espejo Toyota Ipsum	\N	\N	f	t	2026-07-24 14:19:44.077972+00
902	DEPO-00902	1569-L	1569	L	26	Espejo Toyota Mark 2	\N	\N	f	t	2026-07-24 14:19:44.077972+00
903	DEPO-00903	561327-R	561327	R	26	Espejo Toyota Levin 92	\N	\N	f	t	2026-07-24 14:19:44.077972+00
904	DEPO-00904	2200-L	2200	L	26	Espejo Honda Prelude 87-92	\N	\N	f	t	2026-07-24 14:19:44.077972+00
905	DEPO-00905	2200-R	2200	R	26	Espejo Honda Prelude 87-92	\N	\N	f	t	2026-07-24 14:19:44.077972+00
906	DEPO-00906	4675-2-L	4675-2	L	26	Espejo Nissan b14 Largo Eléctrico 3 pines	\N	\N	f	t	2026-07-24 14:19:44.077972+00
907	DEPO-00907	4675-2-R	4675-2	R	26	Espejo Nissan b14 Largo Eléctrico 3 pines	\N	\N	f	t	2026-07-24 14:19:44.077972+00
908	DEPO-00908	8247-R	8247	R	26	Espejo Nissan Pulsar eléctrico 3 pines	\N	\N	f	t	2026-07-24 14:19:44.077972+00
909	DEPO-00909	5069-L	5069	L	26	Espejo Subaru Impreza	\N	\N	f	t	2026-07-24 14:19:44.077972+00
910	DEPO-00910	5069-R	5069	R	26	Espejo Subaru Impreza	\N	\N	f	t	2026-07-24 14:19:44.077972+00
911	DEPO-00911	EH-MITSUBISHI	EH-MITSUBISHI	\N	28	Estuché de herramientas Mitsubishi Negro	\N	\N	f	t	2026-07-24 14:19:44.077972+00
912	DEPO-00912	EH-DAIHATSU	EH-DAIHATSU	\N	28	Estuché de herramientas DAIHATSU azul	\N	\N	f	t	2026-07-24 14:19:44.077972+00
913	DEPO-00913	B38-C-L	B38-C	L	26	Espejo Nissan e25 brazo cromado	\N	\N	f	t	2026-07-24 14:19:44.077972+00
914	DEPO-00914	BU-SURF-F-L	BU-SURF-F	L	12	Buchera de fibra Hilux Surf	\N	\N	f	t	2026-07-24 14:19:44.077972+00
915	DEPO-00915	220-75539-L	220-75539	L	64	Stop STARLET EP82 TURBO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
916	DEPO-00916	7362-L	7362	L	64	STOP TOYOTA CALDINA A MUELLE ROJO BLANCO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
917	DEPO-00917	7362-R	7362	R	64	STOP TOYOTA CALDINA A MUELLE ROJO BLANCO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
918	DEPO-00918	20-120-R	20-120	R	64	STOP TOYOTA CORONA 1983 (rojo / Naranja)	\N	\N	f	t	2026-07-24 14:19:44.077972+00
919	DEPO-00919	7157-R	7157	R	64	Stop CARIB 80	\N	\N	f	t	2026-07-24 14:19:44.077972+00
920	DEPO-00920	TD-30-L	TD-30	L	25	EMBELLECEDOR DE MALETERO MITSUBISHI LANCER EVO 6	\N	\N	f	t	2026-07-24 14:19:44.077972+00
921	DEPO-00921	TD-30-R	TD-30	R	25	EMBELLECEDOR DE MALETERO MITSUBISHI LANCER EVO 6	\N	\N	f	t	2026-07-24 14:19:44.077972+00
922	DEPO-00922	1159-R	1159	R	29	Farol Toyota Varios	\N	\N	f	t	2026-07-24 14:19:44.077972+00
923	DEPO-00923	212-1166-L	212-1166	L	29	Farol Toyota. rav 4 97	\N	\N	f	t	2026-07-24 14:19:44.077972+00
924	DEPO-00924	212-1166-R	212-1166	R	29	Farol Toyota. rav 4 97	\N	\N	f	t	2026-07-24 14:19:44.077972+00
925	DEPO-00925	47-59-L	47-59	L	64	Stop BLUBIRT 96	\N	\N	f	t	2026-07-24 14:19:44.077972+00
926	DEPO-00926	13-38-L	13-38	L	29	FAROL TOYOTASPACIO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
927	DEPO-00927	13-38-R	13-38	R	29	Farol Toyota Spacio	\N	\N	f	t	2026-07-24 14:19:44.077972+00
928	DEPO-00928	215-1129-L	215-1129	L	\N	215-1129-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
929	DEPO-00929	215-1129-R	215-1129	R	\N	215-1129-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
930	DEPO-00930	212-1112-TYC-L	212-1112-TYC	L	29	Farol Toyota COROLLA 90 CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
931	DEPO-00931	212-1112-TYC-R	212-1112-TYC	R	29	Farol Toyota COROLLA 90 CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
932	DEPO-00932	212-1112-L	212-1112	L	\N	212-1112-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
933	DEPO-00933	212-1112-R	212-1112	R	\N	212-1112-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
934	DEPO-00934	1602-L	1602	L	29	FAROL NISSAN SUNNY 2005	\N	\N	f	t	2026-07-24 14:19:44.077972+00
935	DEPO-00935	1602-R	1602	R	29	FAROL NISSAN SUNNY 2005	\N	\N	f	t	2026-07-24 14:19:44.077972+00
936	DEPO-00936	001-6840-L	001-6840	L	29	FAROL MAZDA BONGO SGL5 95	\N	\N	f	t	2026-07-24 14:19:44.077972+00
937	DEPO-00937	001-6840-R	001-6840	R	29	FAROL MAZDA BONGO SGL5 95	\N	\N	f	t	2026-07-24 14:19:44.077972+00
938	DEPO-00938	214-1203-R	214-1203	R	9	BICEL MITSUBISHI MONTERO 90	\N	\N	f	t	2026-07-24 14:19:44.077972+00
939	DEPO-00939	214-1128-L	214-1128	L	\N	214-1128-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
940	DEPO-00940	214-1128-R	214-1128	R	\N	214-1128-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
941	DEPO-00941	4413-L	4413	L	29	FAROL TOYOTA GAIA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
942	DEPO-00942	4413-R	4413	R	29	FAROL TOYOTA GAIA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
943	DEPO-00943	2650-L	2650	L	29	FAROL TOYOTA GRANVIA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
944	DEPO-00944	2650-R	2650	R	29	FAROL TOYOTA GRANVIA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
945	DEPO-00945	P0286-L	P0286	L	\N	P0286-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
946	DEPO-00946	P0286-R	P0286	R	\N	P0286-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
947	DEPO-00947	212-1105-L	212-1105	L	\N	212-1105-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
948	DEPO-00948	212-1105-R	212-1105	R	\N	212-1105-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
949	DEPO-00949	CP-DOMINGO	CP-DOMINGO	\N	19	COLA DE PATO SUBARU DOMINGO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
950	DEPO-00950	CP-MIT-GRANDIS	CP-MIT-GRANDIS	\N	19	COLA DE PATO MITSUBISHI GRANDIS	\N	\N	f	t	2026-07-24 14:19:44.077972+00
951	DEPO-00951	VI-S-DOM-89-F-L	VI-S-DOM-89-F	L	10	BISEL SUBARU DOMINGO RASPADILLO ( FIBRA )	\N	\N	f	t	2026-07-24 14:19:44.077972+00
952	DEPO-00952	VI-S-DOM-89-F-R	VI-S-DOM-89-F	R	10	BISEL SUBARU DOMINGO RASPADILLO (FIBRA )	\N	\N	f	t	2026-07-24 14:19:44.077972+00
953	DEPO-00953	VI-S-DOM-89-F-L	VI-S-DOM-89-F	L	10	BISEL SUBARU DOMINGO RASPADILLO JAPONÉS	\N	\N	f	t	2026-07-24 14:19:44.077972+00
954	DEPO-00954	VI-S-DOM-89-F-R	VI-S-DOM-89-F	R	10	BISEL SUBARU DOMINGO RASPADILLO JAPONÉS	\N	\N	f	t	2026-07-24 14:19:44.077972+00
955	DEPO-00955	J-TOY-CALGT-F	J-TOY-CALGT-F	\N	37	JALADOR DE PUERTA TRASERA TOYOTA CALDINA GT	\N	\N	f	t	2026-07-24 14:19:44.077972+00
956	DEPO-00956	212-1592-B-K-L	212-1592-B-K	L	36	GUIÑADOR TOYOTA COROLLA SAPITO NEGRO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
957	DEPO-00957	212-1592-B-K-R	212-1592-B-K	R	36	GUIÑADOR TOYOTA COROLLA SAPITO NEGRO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
958	DEPO-00958	212-1126-L	212-1126	L	\N	212-1126-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
959	DEPO-00959	20-316-L	20-316	L	\N	20-316-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
960	DEPO-00960	1266-L	1266	L	\N	1266-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
961	DEPO-00961	216-1139-R	216-1139	R	\N	216-1139-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
962	DEPO-00962	20-143-L	20-143	L	\N	20-143-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
963	DEPO-00963	12-417-L	12-417	L	\N	12-417-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
964	DEPO-00964	08423-42040	08423-42040	\N	43	MASACARA TOYOTA RAV 4 TRD	\N	\N	f	t	2026-07-24 14:19:44.077972+00
965	DEPO-00965	71741-80G00	71741-80G00	\N	49	MASCARA SUZUKI SWIFT IGNIS	\N	\N	f	t	2026-07-24 14:19:44.077972+00
966	DEPO-00966	62310-N00	62310-N00	\N	49	MASCARA NISSAAN CUSTOM CROMADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
967	DEPO-00967	PALOGENOS-MIT-JUN	PALOGENOS-MIT-JUN	\N	54	PORTA ALÓGENOS MITSUBISHI JUNIOR SOBRE EL PARACHOQUE	\N	\N	f	t	2026-07-24 14:19:44.077972+00
968	DEPO-00968	F-TSU-SUB-FOR	F-TSU-SUB-FOR	\N	70	TOMA DE AIRE TSUNAMI SUBARU FORESTER	\N	\N	f	t	2026-07-24 14:19:44.077972+00
969	DEPO-00969	F-TSU-SUB-IMP	F-TSU-SUB-IMP	\N	70	TOMA DE AIRE TSUNAMI SUBARU IMPREZA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
970	DEPO-00970	C-TSU-SUB-UNI	C-TSU-SUB-UNI	\N	70	TOMA DE AIRE TSUNAMI UNIVERSAL CARBONO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
971	DEPO-00971	TD-06	TD-06	\N	72	TURBO NUEVO SUBARU EJ20 TURBO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
972	DEPO-00972	212-1156-L	212-1156	L	29	FAROL TOYOTA CALDINA 97 ( oreja agachada )	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1044	DEPO-01044	218-1105-L	218-1105	L	\N	218-1105-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
973	DEPO-00973	212-1156-R	212-1156	R	29	FAROL TOYOTA CALDINA 97 ( oreja agachada )	\N	\N	f	t	2026-07-24 14:19:44.077972+00
974	DEPO-00974	20-260-R	20-260	R	\N	20-260-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
975	DEPO-00975	CP-SUB-FOR-OEM	CP-SUB-FOR-OEM	\N	19	Cola DE PATO SUBARU FORESTER 2000 JAPONÉS	\N	\N	f	t	2026-07-24 14:19:44.077972+00
976	DEPO-00976	13-29-L	13-29	L	64	Stop COROLLA 89	\N	\N	f	t	2026-07-24 14:19:44.077972+00
977	DEPO-00977	OEW2037	OEW2037	\N	64	STOP DE MALETERA MITSUBISHI MONTERO (terecera luz )	\N	\N	f	t	2026-07-24 14:19:44.077972+00
978	DEPO-00978	221-1975-L	221-1975	L	64	STOP HYUNDAI I10 2011-2012	\N	\N	f	t	2026-07-24 14:19:44.077972+00
979	DEPO-00979	221-1975-R	221-1975	R	64	STOP HYUNDAI I10 2011-2012	\N	\N	f	t	2026-07-24 14:19:44.077972+00
980	DEPO-00980	221-1979-L	221-1979	L	64	STOP HYUNDAI I10 2014-2016	\N	\N	f	t	2026-07-24 14:19:44.077972+00
981	DEPO-00981	315-1934-PTU-VC	315-1934-PTU-VC	\N	63	SET	\N	\N	f	t	2026-07-24 14:19:44.077972+00
982	DEPO-00982	218-1937-L	218-1937	L	64	STOP SUZUKI VITARA XL7 CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
983	DEPO-00983	218-1937-R	218-1937	R	64	STOP SUZUKI VITARA XL7 CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
984	DEPO-00984	212-19F1-PTA	212-19F1-PTA	\N	63	SET	\N	\N	f	t	2026-07-24 14:19:44.077972+00
985	DEPO-00985	216-19AG-L	216-19AG	L	64	STOP MAZDA BT50 2015	\N	\N	f	t	2026-07-24 14:19:44.077972+00
986	DEPO-00986	216-19AG-R	216-19AG	R	64	STOP MAZDA BT50 2015	\N	\N	f	t	2026-07-24 14:19:44.077972+00
987	DEPO-00987	214-1140-L	214-1140	L	29	FAROL MITSUBISHI LANCER 95	\N	\N	f	t	2026-07-24 14:19:44.077972+00
988	DEPO-00988	214-1140-R	214-1140	R	29	FAROL MITSUBISHI LANCER 95	\N	\N	f	t	2026-07-24 14:19:44.077972+00
989	DEPO-00989	218-1164-R	218-1164	R	\N	218-1164-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
990	DEPO-00990	214-1556-L	214-1556	L	45	Media luz MITSUBISHI pajero 96	\N	\N	f	t	2026-07-24 14:19:44.077972+00
991	DEPO-00991	214-1556-R	214-1556	R	45	Media luz MITSUBISHI pajero 96	\N	\N	f	t	2026-07-24 14:19:44.077972+00
992	DEPO-00992	212-11T2-R	212-11T2	R	29	FAROL TOYOTA HILUX VIGO 2011	\N	\N	f	t	2026-07-24 14:19:44.077972+00
993	DEPO-00993	215-1427-R	215-1427	R	45	Media luz Nissan patrol 95	\N	\N	f	t	2026-07-24 14:19:44.077972+00
994	DEPO-00994	217-1531-L	217-1531	L	46	MIEDIA LUZ HONDA CIVIC 88	\N	\N	f	t	2026-07-24 14:19:44.077972+00
995	DEPO-00995	217-1531-R	217-1531	R	46	MIEDIA LUZ HONDA CIVIC 88	\N	\N	f	t	2026-07-24 14:19:44.077972+00
996	DEPO-00996	218-1151-L	218-1151	L	29	FAROL SUZUKI SWIFT 2011-2016	\N	\N	f	t	2026-07-24 14:19:44.077972+00
997	DEPO-00997	218-1151-R	218-1151	R	29	FAROL SUZUKI SWIFT 2011-2016	\N	\N	f	t	2026-07-24 14:19:44.077972+00
998	DEPO-00998	212-2901N	212-2901N	\N	58	REFLECTOR FJ40	\N	\N	f	t	2026-07-24 14:19:44.077972+00
999	DEPO-00999	314-1132-PXAS2-L	314-1132-PXAS2	L	29	FAROL MITSUBISHI ECLIPSE SPYDER OJO DE ÁNGEL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1000	DEPO-01000	314-1132-PXAS2-R	314-1132-PXAS2	R	29	FAROL MITSUBISHI ECLIPSE SPYDER OJO DE ÁNGEL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1001	DEPO-01001	860074	860074	\N	\N	860074	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1002	DEPO-01002	870107-O	870107-O	\N	\N	870107-O	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1003	DEPO-01003	87005-G	87005-G	\N	\N	87005-G	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1004	DEPO-01004	87006-G	87006-G	\N	\N	87006-G	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1005	DEPO-01005	87009-G	87009-G	\N	\N	87009-G	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1006	DEPO-01006	870121-G	870121-G	\N	\N	870121-G	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1007	DEPO-01007	SZC-527	SZC-527	\N	55	PRENSA EXEDY SUZUKI APV	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1008	DEPO-01008	MBD-005U	MBD-005U	\N	22	DISCO DE EMBREAGUE EXEDY SUZUKI APV	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1009	DEPO-01009	T-NISS-STOP-F-L	T-NISS-STOP-F	L	68	TAPA DE STOP NISSAN CUSTOM FIBRA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1010	DEPO-01010	T-NISS-STOP-F-R	T-NISS-STOP-F	R	68	TAPA DE STOP NISSAN CUSTOM FIBRA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1011	DEPO-01011	400300	400300	\N	\N	400300	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1012	DEPO-01012	CH-216071	CH-216071	\N	\N	CH-216071	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1013	DEPO-01013	MB574333	MB574333	\N	50	PARACHOQUE TRASERO MITSUBISHI EVO 9	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1014	DEPO-01014	71811-65D30	71811-65D30	\N	50	PARACHOQUE TRASERO SUZUKI GRAN VITARA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1015	DEPO-01015	YY213M-L	YY213M	L	26	ESPEJO B13	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1016	DEPO-01016	YY213M-R	YY213M	R	24	ELSEJO B13	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1017	DEPO-01017	TY8002B-L	TY8002B	L	59	RETROVISOR TOYOTA HILUX MILENIUM CROMADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1018	DEPO-01018	222110-L	222110	L	\N	222110-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1019	DEPO-01019	TY8022-L	TY8022	L	26	ESPEJO TOYOTA HILUX VIGO ELÉCTRICO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1020	DEPO-01020	YT7286-L	YT7286	L	26	ESPEJO SUZUKI ALTO 2011	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1021	DEPO-01021	YT7286-R	YT7286	R	26	ESPEJO SUZUKI ALTO 2011	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1022	DEPO-01022	219-1405-L	219-1405	L	\N	219-1405-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1023	DEPO-01023	219-1405-R	219-1405	R	\N	219-1405-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1024	DEPO-01024	Am0709-L	Am0709	L	38	Jeep Cherokee vicel	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1025	DEPO-01025	215-1977	215-1977	\N	\N	215-1977	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1026	DEPO-01026	220-6693-L	220-6693	L	64	STOP NISSAN SKYLINE	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1027	DEPO-01027	220-6693-R	220-6693	R	64	STOP NISSAN SKYLINE	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1028	DEPO-01028	215-19AA-L	215-19AA	L	\N	215-19AA-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1029	DEPO-01029	SZ04092BA	SZ04092BA	\N	\N	SZ04092BA	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1030	DEPO-01030	SZ07067GA	SZ07067GA	\N	\N	SZ07067GA	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1031	DEPO-01031	SZ99020AL	SZ99020AL	\N	\N	SZ99020AL	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1032	DEPO-01032	SZ99020AR	SZ99020AR	\N	\N	SZ99020AR	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1033	DEPO-01033	EM-FORESTER-C	EM-FORESTER-C	\N	25	Embellecedor FORESTER CARBONO	350.00	\N	f	t	2026-07-24 14:19:44.077972+00
1034	DEPO-01034	FS8305	FS8305	\N	14	CANDADO DE MOTO / SCOOTER ELÉCTRICO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1035	DEPO-01035	SZ11036A-L	SZ11036A	L	34	GUARDABARRO SUZUKI VITARA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1036	DEPO-01036	SZ11036A-R	SZ11036A	R	34	GUARDABARRO SUZUKI VITARA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1037	DEPO-01037	217-1516-L	217-1516	L	36	Guiñador honda eg negro	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1038	DEPO-01038	217-1516-R	217-1516	R	36	Guiñador honda eg negro	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1039	DEPO-01039	212-1592-R	212-1592	R	45	Media luz COROLLA Mod. 95 ~ 96 AE110. SAPITO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1040	DEPO-01040	212-1670-L	212-1670	L	\N	212-1670-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1041	DEPO-01041	312-1141-L	312-1141	L	29	FAROL TOYOTA RAV 4 99	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1042	DEPO-01042	312-1141-R	312-1141	R	29	FAROL TOYOTA RAV 4 99	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1043	DEPO-01043	215-1111-R	215-1111	R	29	FAROL NISSAN SUNNY B12	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1045	DEPO-01045	218-1105-R	218-1105	R	\N	218-1105-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1046	DEPO-01046	312-1186-L	312-1186	L	\N	312-1186-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1047	DEPO-01047	870043	870043	\N	4	AMORTIGUADOR PROBOX	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1048	DEPO-01048	870090	870090	\N	4	AMORTIGUADOR APV	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1049	DEPO-01049	870052-O	870052-O	\N	\N	870052-O	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1050	DEPO-01050	DS-2007	DS-2007	\N	5	AMORTIGUADORDELANTERO HILUX STAU	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1051	DEPO-01051	M-TOY-rav-f	M-TOY-rav-f	\N	49	MASCARA TOYOTA RAV 4 FIBRA DE VIDRIO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1052	DEPO-01052	870104-G	870104-G	\N	4	AMORTIGUADOR CHARIOT	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1053	DEPO-01053	860009	860009	\N	48	MUÑÓN ESTABILIZADOR LARGO UNIVERSAL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1054	DEPO-01054	860044	860044	\N	48	MUÑÓN SUSPENCION SUPERIRO HIACE LOBO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1055	DEPO-01055	30502-AA051	30502-AA051	\N	60	RODAMIENTO SUBARU EJ 20 SIN TURBO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1056	DEPO-01056	860051	860051	\N	48	MUÑÓN SUSPENCION TOYOTA TERCEL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1057	DEPO-01057	860061	860061	\N	48	MUÑÓN SUSPENCION VANNETE BONGO INFERIOR MAZDA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1058	DEPO-01058	850022	850022	\N	39	JUNTA 24X23 TOY PROBOX	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1059	DEPO-01059	214-1146-L	214-1146	L	29	FAROL MITSUBISHI MONTERO CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1060	DEPO-01060	214-1146-R	214-1146	R	29	FAROL MITSUBISHI MONTERO CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1061	DEPO-01061	123629	123629	\N	61	RÓTULA HIACE LOBO 14X17	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1062	DEPO-01062	214-11A7-R	214-11A7	R	29	FAROL MITSUBISHI MIRAGE	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1063	DEPO-01063	320-1506-R	320-1506	R	36	Guiñador subaru forester	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1064	DEPO-01064	214-1112-L	214-1112	L	29	FAROL MITSUBISHI COLT 87	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1065	DEPO-01065	218-1172-L	218-1172	L	\N	218-1172-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1066	DEPO-01066	218-1172-R	218-1172	R	\N	218-1172-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1067	DEPO-01067	043-1540-L	043-1540	L	64	STOP MITSUBISHI MONTERO BORDE NEGRO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1068	DEPO-01068	043-1540-R	043-1540	R	64	STOP MITSUBISHI MONTERO BORDE NEGRO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1069	DEPO-01069	210-87071-R	210-87071	R	\N	210-87071-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1070	DEPO-01070	215-1968-PXA-L	215-1968-PXA	L	64	STOP CRISTALIZADO NISSAN PATROL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1071	DEPO-01071	215-1968-PXA-R	215-1968-PXA	R	64	STOP CRISTALIZADO NISSAN PATROL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1072	DEPO-01072	212-1915-L	212-1915	L	\N	212-1915-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1073	DEPO-01073	215-1993-R	215-1993	R	\N	215-1993-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1074	DEPO-01074	215-1993-L	215-1993	L	\N	215-1993-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1075	DEPO-01075	317-1513-L	317-1513	L	\N	317-1513-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1076	DEPO-01076	317-1513-R	317-1513	R	\N	317-1513-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1077	DEPO-01077	330-1504-R	330-1504	R	\N	330-1504-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1078	DEPO-01078	TY11106	TY11106	\N	69	TAPABARRO HILUX SURF	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1079	DEPO-01079	441-1177	441-1177	\N	29	FAROL VOLKSWAGEN OJO DE ÁNGEL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1080	DEPO-01080	215-1504-L	215-1504	L	36	Guiñador pick up	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1081	DEPO-01081	215-1504-R	215-1504	R	36	Guiñador PICK UP	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1082	DEPO-01082	220-61871-L	220-61871	L	64	Stop BONGO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1083	DEPO-01083	1188-L	1188	L	29	Farol NISSAN SUNNY b12	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1084	DEPO-01084	212-11AK-L	212-11AK	L	29	FAROL TOYOTA HILUX REVO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1085	DEPO-01085	212-11AK-R	212-11AK	R	29	FAROL TOYOTA HILUX REVO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1086	DEPO-01086	215-1543-L	215-1543	L	36	Guiñador Nissan patrol 87	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1087	DEPO-01087	215-1543-R	215-1543	R	36	Guiñador Nissan patrol 87	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1088	DEPO-01088	333-1608-L	333-1608	L	36	GUIÑADOR CHEVROLET COLORADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1089	DEPO-01089	333-1608-R	333-1608	R	36	GUIÑADOR CHEVROLET COLORADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1090	DEPO-01090	212-19F9-L	212-19F9	L	64	STOP HIACE LOBO TUNNIG	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1091	DEPO-01091	212-19F9-R	212-19F9	R	64	STOP HIACE LOBO TUNNIG	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1092	DEPO-01092	312-1549-L	312-1549	L	36	GUIÑADOR CELICA TOYOTA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1093	DEPO-01093	312-1549-R	312-1549	R	36	GUIÑADOR CELICA TOYOTA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1094	DEPO-01094	333-1636-L	333-1636	L	36	Guiñador jeep renegade	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1095	DEPO-01095	5283-L	5283	L	59	RETROVISOR DE CAPO TOYOTA HILUX SURF	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1096	DEPO-01096	314-1146-L	314-1146	L	\N	314-1146-L	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1097	DEPO-01097	212-1989-L	212-1989	L	64	Stop corolla 90	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1098	DEPO-01098	212-1989-R	212-1989	R	64	Stop corolla 90	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1099	DEPO-01099	44-3-R	44-3	R	29	Farol Toyota ipsum	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1100	DEPO-01100	21-16-R	21-16	R	29	FAROL TOYORA. ALDINA ORIGINAL	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1101	DEPO-01101	551-19AJ-R	551-19AJ	R	64	STOP RENAULT KIWID	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1102	DEPO-01102	215-1562-L	215-1562	L	45	MEDIA LUZ NISSAN SUNNY 90	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1103	DEPO-01103	214-1112-L	214-1112	L	29	Farol lancer 89	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1104	DEPO-01104	215-1614-L	215-1614	L	36	Guiñador Nissan parachoques mini datsun	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1105	DEPO-01105	215-1614-R	215-1614	R	36	Guiñador Nissan parachoques mini datsun	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1106	DEPO-01106	215-1562-R	215-1562	R	45	MEDIA LUZ NISSAN SUNNY 90	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1107	DEPO-01107	214-1531-R	214-1531	R	45	Media luz montero 92	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1108	DEPO-01108	331-1524-L	331-1524	L	36	Guiñador Ford Explorer 99	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1109	DEPO-01109	331-1524-R	331-1524	R	36	Guiñador Ford Explorer 99	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1110	DEPO-01110	212-15D8-L	212-15D8	L	45	MEDIA LUZ COROLLA 92 CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1111	DEPO-01111	212-15D8-R	212-15D8	R	45	MEDIA LUZ COROLLA 92 CRISTALIZADO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1112	DEPO-01112	212-1580-L	212-1580	L	45	MEDIA LUZ TOYOTA CALDINA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1113	DEPO-01113	212-1580-R	212-1580	R	45	MEDIA LUZ TOYOTA CALDINA	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1114	DEPO-01114	218-1610-L	218-1610	L	66	SUZUKI NEW VITARA ALÓGENO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1115	DEPO-01115	218-1610-R	218-1610	R	66	SUZUKI NEW VITARA ALÓGENO	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1116	DEPO-01116	222111-L	222111	L	26	Espejo COROLLA 92 NEGRO R/L Retrovisor MAMUT Unidad CARIB SPRINTER	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1117	DEPO-01117	222110-R	222110	R	\N	222110-R	\N	\N	t	t	2026-07-24 14:19:44.077972+00
1118	DEPO-01118	44-26-L	44-26	L	36	Guiñador Toyota ipsum	\N	\N	f	t	2026-07-24 14:19:44.077972+00
1119	DEPO-01119	44-26-R	44-26	R	36	Guiñador Toyota ipsum	\N	\N	f	t	2026-07-24 14:19:44.077972+00
\.


--
-- Data for Name: item_alias; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.item_alias (alias_id, item_id, alias, source, created_at) FROM stdin;
1	1	2644	legacy	2026-07-24 14:19:44.077972+00
2	1	212-15D5 DE HICE	legacy	2026-07-24 14:19:44.077972+00
3	1	2644-R	legacy	2026-07-24 14:19:44.077972+00
4	2	SAE-40	legacy	2026-07-24 14:19:44.077972+00
5	2	Aceite PARA MOTOR	legacy	2026-07-24 14:19:44.077972+00
6	3	210-0202-002-L	legacy	2026-07-24 14:19:44.077972+00
7	3	210-0202-002	legacy	2026-07-24 14:19:44.077972+00
8	3	Alogeno BONGO	legacy	2026-07-24 14:19:44.077972+00
9	4	210-0202-002-R	legacy	2026-07-24 14:19:44.077972+00
10	4	210-0202-002	legacy	2026-07-24 14:19:44.077972+00
11	4	Alogeno BONGO	legacy	2026-07-24 14:19:44.077972+00
12	5	Alogeno JUNIOR	legacy	2026-07-24 14:19:44.077972+00
13	5	846	legacy	2026-07-24 14:19:44.077972+00
14	5	846-L	legacy	2026-07-24 14:19:44.077972+00
15	6	Alogeno JUNIOR	legacy	2026-07-24 14:19:44.077972+00
16	6	846	legacy	2026-07-24 14:19:44.077972+00
17	6	846-R	legacy	2026-07-24 14:19:44.077972+00
18	7	13-42	legacy	2026-07-24 14:19:44.077972+00
19	7	Alogeno LEVIN 97	legacy	2026-07-24 14:19:44.077972+00
20	7	13-42-L	legacy	2026-07-24 14:19:44.077972+00
21	8	13-42	legacy	2026-07-24 14:19:44.077972+00
22	8	Alogeno LEVIN 97	legacy	2026-07-24 14:19:44.077972+00
23	8	13-42-R	legacy	2026-07-24 14:19:44.077972+00
24	9	19027	legacy	2026-07-24 14:19:44.077972+00
25	9	Alogeno SUZUKI VITARA	legacy	2026-07-24 14:19:44.077972+00
26	9	19027-L	legacy	2026-07-24 14:19:44.077972+00
27	10	19027	legacy	2026-07-24 14:19:44.077972+00
28	10	Alogeno SUZUKI VITARA	legacy	2026-07-24 14:19:44.077972+00
29	10	19027-R	legacy	2026-07-24 14:19:44.077972+00
30	11	Alogeno SWIFT	legacy	2026-07-24 14:19:44.077972+00
31	11	400-L	legacy	2026-07-24 14:19:44.077972+00
32	11	400	legacy	2026-07-24 14:19:44.077972+00
33	12	Alogeno SWIFT	legacy	2026-07-24 14:19:44.077972+00
34	12	400	legacy	2026-07-24 14:19:44.077972+00
35	12	400-R	legacy	2026-07-24 14:19:44.077972+00
36	13	A-VAR	legacy	2026-07-24 14:19:44.077972+00
37	13	Alogeno VARIOS	legacy	2026-07-24 14:19:44.077972+00
38	14	Alogeno FORESTER	legacy	2026-07-24 14:19:44.077972+00
39	14	114-20257-TW-R	legacy	2026-07-24 14:19:44.077972+00
40	14	114-20257-TW	legacy	2026-07-24 14:19:44.077972+00
41	15	Alogeno FORESTER	legacy	2026-07-24 14:19:44.077972+00
42	15	20597-C	legacy	2026-07-24 14:19:44.077972+00
43	16	20597-Y	legacy	2026-07-24 14:19:44.077972+00
44	16	Alogeno FORESTER AMARILLO	legacy	2026-07-24 14:19:44.077972+00
45	17	Amortiguador IPSUM 2004 TRASERO	legacy	2026-07-24 14:19:44.077972+00
46	17	870118-G	legacy	2026-07-24 14:19:44.077972+00
47	18	Amortiguador TOYOTA STARLET	legacy	2026-07-24 14:19:44.077972+00
48	18	121118	legacy	2026-07-24 14:19:44.077972+00
49	19	Amortiguador CARRY TRASERO	legacy	2026-07-24 14:19:44.077972+00
50	19	87017	legacy	2026-07-24 14:19:44.077972+00
51	20	Amortiguador COROLLA TRASERO L	legacy	2026-07-24 14:19:44.077972+00
52	20	870014	legacy	2026-07-24 14:19:44.077972+00
53	21	870025-G	legacy	2026-07-24 14:19:44.077972+00
54	21	Amortiguador DE CALDINA RTRASERO A MUELLE	legacy	2026-07-24 14:19:44.077972+00
55	22	870106-G	legacy	2026-07-24 14:19:44.077972+00
56	22	Amortiguador DE CARRY	legacy	2026-07-24 14:19:44.077972+00
57	23	87009-O	legacy	2026-07-24 14:19:44.077972+00
58	23	Amortiguador DE COROLLA TRASERO 90 º	legacy	2026-07-24 14:19:44.077972+00
59	24	Amortiguador DE PATHINDER TERRANO TRASERO 56210-0W001	legacy	2026-07-24 14:19:44.077972+00
60	24	870077-G	legacy	2026-07-24 14:19:44.077972+00
61	25	AP-P	legacy	2026-07-24 14:19:44.077972+00
62	25	Amortiguador DE Puerta PARES	legacy	2026-07-24 14:19:44.077972+00
63	26	AP-S	legacy	2026-07-24 14:19:44.077972+00
64	26	Amortiguador DE Puerta SUELTOS	legacy	2026-07-24 14:19:44.077972+00
65	27	870089	legacy	2026-07-24 14:19:44.077972+00
66	27	Amortiguador DELANTERO APV	legacy	2026-07-24 14:19:44.077972+00
67	28	DS-2007	legacy	2026-07-24 14:19:44.077972+00
68	28	Amortiguador DELANTERO HILUX 90	legacy	2026-07-24 14:19:44.077972+00
69	29	Amortiguador DELANTERO L	legacy	2026-07-24 14:19:44.077972+00
70	29	870059-G	legacy	2026-07-24 14:19:44.077972+00
71	30	Amortiguador DELANTERO LEVIN TRUENO L	legacy	2026-07-24 14:19:44.077972+00
72	30	870028	legacy	2026-07-24 14:19:44.077972+00
73	31	Amortiguador DELANTERO LEVIN TRUENO R	legacy	2026-07-24 14:19:44.077972+00
74	31	870027	legacy	2026-07-24 14:19:44.077972+00
75	32	870044	legacy	2026-07-24 14:19:44.077972+00
76	32	Amortiguador DELANTERO PROBOX (L)	legacy	2026-07-24 14:19:44.077972+00
77	33	Amortiguador Delantero R-L NOAH LITEACE 97-02 GAS	legacy	2026-07-24 14:19:44.077972+00
78	33	870047-G	legacy	2026-07-24 14:19:44.077972+00
79	34	870105-G	legacy	2026-07-24 14:19:44.077972+00
80	34	Amortiguador DELNTERO CARRY	legacy	2026-07-24 14:19:44.077972+00
81	35	870021-G	legacy	2026-07-24 14:19:44.077972+00
82	35	Amortiguador HIACE	legacy	2026-07-24 14:19:44.077972+00
83	36	Amortiguador HIALUX VIGO DELANTERO SHIBUMI	legacy	2026-07-24 14:19:44.077972+00
84	36	341372	legacy	2026-07-24 14:19:44.077972+00
85	37	Amortiguador HONDA EG TRASERO	legacy	2026-07-24 14:19:44.077972+00
86	37	870065-G	legacy	2026-07-24 14:19:44.077972+00
87	38	Amortiguador IPSUM MODERNO DELANTERO	legacy	2026-07-24 14:19:44.077972+00
88	38	870100-G	legacy	2026-07-24 14:19:44.077972+00
89	39	Amortiguador IZUSU TROPER DELANTERO SHIBUMI	legacy	2026-07-24 14:19:44.077972+00
90	39	2618	legacy	2026-07-24 14:19:44.077972+00
91	40	870026-G	legacy	2026-07-24 14:19:44.077972+00
92	40	Amortiguador LAND CRUISER	legacy	2026-07-24 14:19:44.077972+00
93	41	Amortiguador MONTERO DELANTERO 02	legacy	2026-07-24 14:19:44.077972+00
94	41	870063-G	legacy	2026-07-24 14:19:44.077972+00
95	42	870051-G	legacy	2026-07-24 14:19:44.077972+00
96	42	Amortiguador MONTERO TRASER 98	legacy	2026-07-24 14:19:44.077972+00
97	43	870051-O	legacy	2026-07-24 14:19:44.077972+00
98	43	Amortiguador MONTERO TRASER 98	legacy	2026-07-24 14:19:44.077972+00
99	44	870045	legacy	2026-07-24 14:19:44.077972+00
100	44	Amortiguador PROBOX 4WD 1NZ 4X4 RH	legacy	2026-07-24 14:19:44.077972+00
101	45	870058-G	legacy	2026-07-24 14:19:44.077972+00
102	45	Amortiguador PROBOX NOAH TRASERO	legacy	2026-07-24 14:19:44.077972+00
103	46	870068-G	legacy	2026-07-24 14:19:44.077972+00
104	46	Amortiguador RAV4 DELANTERO	legacy	2026-07-24 14:19:44.077972+00
105	47	Amortiguador SUZUKI ALTO	legacy	2026-07-24 14:19:44.077972+00
106	47	870122	legacy	2026-07-24 14:19:44.077972+00
107	48	A-2159	legacy	2026-07-24 14:19:44.077972+00
108	48	Amortiguador SUZUKI SWIFT L	legacy	2026-07-24 14:19:44.077972+00
109	49	Amortiguador SUZUKI SWIFT R	legacy	2026-07-24 14:19:44.077972+00
110	49	A-2158	legacy	2026-07-24 14:19:44.077972+00
111	50	870060-G	legacy	2026-07-24 14:19:44.077972+00
112	50	Amortiguador SUZUKI VITRA R	legacy	2026-07-24 14:19:44.077972+00
113	51	870047-O	legacy	2026-07-24 14:19:44.077972+00
114	51	Amortiguador TOWN ACE NOAH DELANTERO	legacy	2026-07-24 14:19:44.077972+00
115	52	Amortiguador TOYOTA DELANTERO HIACE	legacy	2026-07-24 14:19:44.077972+00
116	52	870086-G	legacy	2026-07-24 14:19:44.077972+00
117	53	Amortiguador TRASERO CALDINA ESPIRAL (L)	legacy	2026-07-24 14:19:44.077972+00
118	53	870033-G	legacy	2026-07-24 14:19:44.077972+00
119	54	870009-G	legacy	2026-07-24 14:19:44.077972+00
120	54	Amortiguador TRASERO DE COROLLA A GAS	legacy	2026-07-24 14:19:44.077972+00
121	55	870103-G	legacy	2026-07-24 14:19:44.077972+00
122	55	Amortiguador TRASERO MITSUBISHI CHARIOT RVR	legacy	2026-07-24 14:19:44.077972+00
123	56	Amortiguador TRASERO STARLET EP82	legacy	2026-07-24 14:19:44.077972+00
124	56	120079	legacy	2026-07-24 14:19:44.077972+00
125	57	Amortiguador Trasero TOY COROLLA RH AE101-CE100 GAS YOITOKI	legacy	2026-07-24 14:19:44.077972+00
126	57	870013-G	legacy	2026-07-24 14:19:44.077972+00
127	58	870007-G	legacy	2026-07-24 14:19:44.077972+00
128	58	Amortiguador Trasero TOY DIESEL/GASOLINA COR/VAG TOKICO GAS	legacy	2026-07-24 14:19:44.077972+00
129	59	Amortiguador Trasero TOY DIESEL/GASOLINA COR/VAG TOKICO OIL	legacy	2026-07-24 14:19:44.077972+00
130	59	870007-O	legacy	2026-07-24 14:19:44.077972+00
131	60	Amortiguador URVAN CHANCHO E25 DELANTERO	legacy	2026-07-24 14:19:44.077972+00
132	60	810100-G	legacy	2026-07-24 14:19:44.077972+00
133	61	870008-G	legacy	2026-07-24 14:19:44.077972+00
134	61	Amortiguador HIACE TRSERO	legacy	2026-07-24 14:19:44.077972+00
135	62	870096-G	legacy	2026-07-24 14:19:44.077972+00
136	62	Amortiguador TRASERO HIACE 2001-2005 OREJA GRANDE	legacy	2026-07-24 14:19:44.077972+00
137	63	Anticongelante SUPER KOTE COLOR AMARILLO	legacy	2026-07-24 14:19:44.077972+00
138	63	SK-A	legacy	2026-07-24 14:19:44.077972+00
139	64	SK-V	legacy	2026-07-24 14:19:44.077972+00
140	64	Anticongelante SUPER KOTE COLOR VERDE	legacy	2026-07-24 14:19:44.077972+00
141	65	Aro SUBARU DORADO	legacy	2026-07-24 14:19:44.077972+00
142	65	16X7JJ-5	legacy	2026-07-24 14:19:44.077972+00
143	66	Aspa IPSUM 96~97~98~99~2000 VENTILADOR COMPLETO 36,5cmX35,4cm	legacy	2026-07-24 14:19:44.077972+00
144	66	GPC-1001	legacy	2026-07-24 14:19:44.077972+00
145	67	53131-13020	legacy	2026-07-24 14:19:44.077972+00
146	67	53131-13020-R	legacy	2026-07-24 14:19:44.077972+00
147	67	Bisel COROLLA 90	legacy	2026-07-24 14:19:44.077972+00
148	68	Bisel COROLLA KE70 84 212-1231	legacy	2026-07-24 14:19:44.077972+00
149	68	13-31	legacy	2026-07-24 14:19:44.077972+00
150	68	13-31-R	legacy	2026-07-24 14:19:44.077972+00
151	69	13-28-R	legacy	2026-07-24 14:19:44.077972+00
152	69	Bisel COROLLA KE70 84 CON FRANJA BLANCA 212-1227	legacy	2026-07-24 14:19:44.077972+00
153	69	13-28	legacy	2026-07-24 14:19:44.077972+00
154	70	Bisel DE Farol CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
155	70	BF-CALDINA	legacy	2026-07-24 14:19:44.077972+00
156	70	BF-CALDINA-L	legacy	2026-07-24 14:19:44.077972+00
157	71	Bisel DE Farol CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
158	71	BF-CALDINA	legacy	2026-07-24 14:19:44.077972+00
159	71	BF-CALDINA-R	legacy	2026-07-24 14:19:44.077972+00
160	72	BM-JUNIOR	legacy	2026-07-24 14:19:44.077972+00
161	72	Bisel DE Mascara JUNIOR	legacy	2026-07-24 14:19:44.077972+00
162	73	BS-IMPREZA	legacy	2026-07-24 14:19:44.077972+00
163	73	Bisel DE Stop SUBARU IMPREZA	legacy	2026-07-24 14:19:44.077972+00
164	73	BS-IMPREZA-L	legacy	2026-07-24 14:19:44.077972+00
165	74	BS-IMPREZA-R	legacy	2026-07-24 14:19:44.077972+00
166	74	Bisel DE Stop SUBARU IMPREZA	legacy	2026-07-24 14:19:44.077972+00
167	74	BS-IMPREZA	legacy	2026-07-24 14:19:44.077972+00
168	75	53130-95J05	legacy	2026-07-24 14:19:44.077972+00
169	75	53130-95J05-R	legacy	2026-07-24 14:19:44.077972+00
170	75	Bisel HIACE Mod,85~88 Foco CUADRADO 212-1221	legacy	2026-07-24 14:19:44.077972+00
171	76	74081-EX0100	legacy	2026-07-24 14:19:44.077972+00
172	76	Bisel SUNNY 310	legacy	2026-07-24 14:19:44.077972+00
173	76	74081-EX0100-L	legacy	2026-07-24 14:19:44.077972+00
174	77	Brazo de cremallera HIDRAULICO IPSUM (Hilo fino x 1.5 ext.)16X14X1,5	legacy	2026-07-24 14:19:44.077972+00
175	77	860033	legacy	2026-07-24 14:19:44.077972+00
176	78	Brazo de cremallera HIDRAULICO YOITOKI UNIVERSAL 14X16	legacy	2026-07-24 14:19:44.077972+00
177	78	860030	legacy	2026-07-24 14:19:44.077972+00
178	79	860029	legacy	2026-07-24 14:19:44.077972+00
179	79	Brazo de cremallera TOYOTA LARGO YOITOKI Mecanico 14X14	legacy	2026-07-24 14:19:44.077972+00
180	80	860096	legacy	2026-07-24 14:19:44.077972+00
181	80	Brazo de cremallera TOYOTA/NISSAN LARGO YOITOKI Mecanico 14X15	legacy	2026-07-24 14:19:44.077972+00
182	81	BU-SURF-F	legacy	2026-07-24 14:19:44.077972+00
183	81	Buchera HILUX SURF 96 FIBRA	legacy	2026-07-24 14:19:44.077972+00
184	81	BU-SURF-F-R	legacy	2026-07-24 14:19:44.077972+00
185	82	Caliper STI MORDAZA	legacy	2026-07-24 14:19:44.077972+00
186	82	CALIPER-VAR	legacy	2026-07-24 14:19:44.077972+00
187	83	GF-DOMINGO-L	legacy	2026-07-24 14:19:44.077972+00
188	83	Cantonera METALICA DE SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
189	83	GF-DOMINGO	legacy	2026-07-24 14:19:44.077972+00
190	84	GF-DOMINGO-R	legacy	2026-07-24 14:19:44.077972+00
191	84	Cantonera METALICA DE SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
192	84	GF-DOMINGO	legacy	2026-07-24 14:19:44.077972+00
193	85	Capota FORESTER 97	legacy	2026-07-24 14:19:44.077972+00
194	85	C-FORESTER-97	legacy	2026-07-24 14:19:44.077972+00
195	86	Capota HONDA CIVIC EG	legacy	2026-07-24 14:19:44.077972+00
196	86	C-CIVIC-92	legacy	2026-07-24 14:19:44.077972+00
197	87	C-EVO4	legacy	2026-07-24 14:19:44.077972+00
198	87	Capota MITSUBISHI EVOLUTION 4	legacy	2026-07-24 14:19:44.077972+00
199	88	Capota SUZUKI CULTUS	legacy	2026-07-24 14:19:44.077972+00
200	88	C-CULTUS-91	legacy	2026-07-24 14:19:44.077972+00
201	89	C-VITARA-97	legacy	2026-07-24 14:19:44.077972+00
202	89	Capota SUZUKI VITARA 97 ESCUDO	legacy	2026-07-24 14:19:44.077972+00
203	90	C-SURF-96	legacy	2026-07-24 14:19:44.077972+00
204	90	Capota TOYOTA HILUX SURF	legacy	2026-07-24 14:19:44.077972+00
205	91	CAT-300	legacy	2026-07-24 14:19:44.077972+00
206	91	Capuchón CON TOPE DE Amortiguador	legacy	2026-07-24 14:19:44.077972+00
207	92	Capuchón de cremallera HIDRAULICO CORTO MAMUT	legacy	2026-07-24 14:19:44.077972+00
208	92	400402	legacy	2026-07-24 14:19:44.077972+00
209	93	Capuchón de JUNTA CE90/AE90 MAMUT	legacy	2026-07-24 14:19:44.077972+00
210	93	400001	legacy	2026-07-24 14:19:44.077972+00
211	94	Capuchón de JUNTA CE90/AE90 MAMUT	legacy	2026-07-24 14:19:44.077972+00
212	94	400002	legacy	2026-07-24 14:19:44.077972+00
213	95	Capuchón de TRICETA Toyota AE90~CE90 MAMUT	legacy	2026-07-24 14:19:44.077972+00
214	95	400200	legacy	2026-07-24 14:19:44.077972+00
215	96	Chisguete DE PARCHOQUE MONTERO	legacy	2026-07-24 14:19:44.077972+00
216	96	CHI-P-M	legacy	2026-07-24 14:19:44.077972+00
217	97	CP-RAV4-F	legacy	2026-07-24 14:19:44.077972+00
218	97	Cola DE PATO RAV 4 98 FIBRA	legacy	2026-07-24 14:19:44.077972+00
219	98	Cola DE PATO RAV 4 98 ORIGINAL	legacy	2026-07-24 14:19:44.077972+00
220	98	CP-RAV4	legacy	2026-07-24 14:19:44.077972+00
221	99	Cola DE PATO SUBARU FORESTER 2000 Fibra vidrio	legacy	2026-07-24 14:19:44.077972+00
222	99	CP-FORESTER00-F	legacy	2026-07-24 14:19:44.077972+00
223	100	Cola DE PATO SUBARU FORESTER 97	legacy	2026-07-24 14:19:44.077972+00
224	100	CP-FORESTER97	legacy	2026-07-24 14:19:44.077972+00
225	101	CON-VAR	legacy	2026-07-24 14:19:44.077972+00
226	101	Consola CENTRAL	legacy	2026-07-24 14:19:44.077972+00
227	102	Consola de Radio CARIB Café	legacy	2026-07-24 14:19:44.077972+00
228	102	CON-R-VAR	legacy	2026-07-24 14:19:44.077972+00
229	103	212-1592	legacy	2026-07-24 14:19:44.077972+00
230	103	Media luz COROLLA Mod. 95 ~ 96 AE110. SAPITO	legacy	2026-07-24 14:19:44.077972+00
231	103	212-1592-L	legacy	2026-07-24 14:19:44.077972+00
232	104	Cruceta de dirección Completa TOYOTA AE 90 ( CARDAN ) YOI-273	legacy	2026-07-24 14:19:44.077972+00
233	104	121222	legacy	2026-07-24 14:19:44.077972+00
234	105	121219	legacy	2026-07-24 14:19:44.077972+00
235	105	Cruceta de dirección Completa TOYOTA TURING HIDRAULICO CORTO YOI-265	legacy	2026-07-24 14:19:44.077972+00
236	106	Cruceta de dirección Completa YOI-272 UNIVERSAL	legacy	2026-07-24 14:19:44.077972+00
237	106	121221	legacy	2026-07-24 14:19:44.077972+00
238	107	FJD005U	legacy	2026-07-24 14:19:44.077972+00
239	107	Disco Subaru DOMINGO	legacy	2026-07-24 14:19:44.077972+00
240	108	CPU-1F	legacy	2026-07-24 14:19:44.077972+00
241	108	ECU SUBARU	legacy	2026-07-24 14:19:44.077972+00
242	109	CPU-4W	legacy	2026-07-24 14:19:44.077972+00
243	109	ECU SUBARU	legacy	2026-07-24 14:19:44.077972+00
244	110	ECU TOYOTA 3SG	legacy	2026-07-24 14:19:44.077972+00
245	110	CPU-3S-G	legacy	2026-07-24 14:19:44.077972+00
246	111	21-32-R	legacy	2026-07-24 14:19:44.077972+00
247	111	21-32	legacy	2026-07-24 14:19:44.077972+00
248	111	Embellecedor CALDINA TURING	legacy	2026-07-24 14:19:44.077972+00
249	112	Embellecedor MITSUBISHI EVOLUCION LANCER1,2,3	legacy	2026-07-24 14:19:44.077972+00
250	112	1149-204-L	legacy	2026-07-24 14:19:44.077972+00
251	112	1149-204	legacy	2026-07-24 14:19:44.077972+00
252	113	Embellecedor MITSUBISHI EVOLUCION LANCER 1,2,3	legacy	2026-07-24 14:19:44.077972+00
253	113	1149-204-R	legacy	2026-07-24 14:19:44.077972+00
254	113	1149-204	legacy	2026-07-24 14:19:44.077972+00
255	114	2143-L	legacy	2026-07-24 14:19:44.077972+00
256	114	2143	legacy	2026-07-24 14:19:44.077972+00
257	114	Embellecedor CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
258	115	2143	legacy	2026-07-24 14:19:44.077972+00
259	115	2143-R	legacy	2026-07-24 14:19:44.077972+00
260	115	Embellecedor CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
261	116	20-207-L	legacy	2026-07-24 14:19:44.077972+00
262	116	Embellecedor CORONA 88-89	legacy	2026-07-24 14:19:44.077972+00
263	116	20-207	legacy	2026-07-24 14:19:44.077972+00
264	117	Embellecedor CORONA 88-89	legacy	2026-07-24 14:19:44.077972+00
265	117	20-207	legacy	2026-07-24 14:19:44.077972+00
266	117	20-207-R	legacy	2026-07-24 14:19:44.077972+00
267	118	Embellecedor FORESTER FIBRA	legacy	2026-07-24 14:19:44.077972+00
268	118	EM-FORESTER-F	legacy	2026-07-24 14:19:44.077972+00
269	119	Espejo HONDA EG ELECTRICO 3 PINES	legacy	2026-07-24 14:19:44.077972+00
270	119	11216-R	legacy	2026-07-24 14:19:44.077972+00
271	119	11216	legacy	2026-07-24 14:19:44.077972+00
272	120	010467-L	legacy	2026-07-24 14:19:44.077972+00
273	120	Espejo ATRAIL CROMADO	legacy	2026-07-24 14:19:44.077972+00
274	120	010467	legacy	2026-07-24 14:19:44.077972+00
275	121	010467-R	legacy	2026-07-24 14:19:44.077972+00
276	121	Espejo ATRAIL CROMADO	legacy	2026-07-24 14:19:44.077972+00
277	121	010467	legacy	2026-07-24 14:19:44.077972+00
278	122	547139-L	legacy	2026-07-24 14:19:44.077972+00
279	122	Espejo CAMRY	legacy	2026-07-24 14:19:44.077972+00
280	122	547139	legacy	2026-07-24 14:19:44.077972+00
281	123	2960	legacy	2026-07-24 14:19:44.077972+00
282	123	2960-L	legacy	2026-07-24 14:19:44.077972+00
283	123	Espejo CHAPULIN HUEVO	legacy	2026-07-24 14:19:44.077972+00
284	124	2960	legacy	2026-07-24 14:19:44.077972+00
285	124	2960-R	legacy	2026-07-24 14:19:44.077972+00
286	124	Espejo CHAPULIN HUEVO	legacy	2026-07-24 14:19:44.077972+00
287	125	Espejo CHARIOT RVR	legacy	2026-07-24 14:19:44.077972+00
288	125	3719-L	legacy	2026-07-24 14:19:44.077972+00
289	125	3719	legacy	2026-07-24 14:19:44.077972+00
290	126	Espejo COROLLA 92 ELECTRICO 3 PINES	legacy	2026-07-24 14:19:44.077972+00
291	126	2277-L	legacy	2026-07-24 14:19:44.077972+00
292	126	2277	legacy	2026-07-24 14:19:44.077972+00
293	127	222111	legacy	2026-07-24 14:19:44.077972+00
294	127	Espejo COROLLA 92 NEGRO R/L Retrovisor MAMUT Unidad CARIB SPRINTER	legacy	2026-07-24 14:19:44.077972+00
295	127	222111-R	legacy	2026-07-24 14:19:44.077972+00
296	128	Espejo DATAUN ATRAIL NEGRO	legacy	2026-07-24 14:19:44.077972+00
297	128	010466-L	legacy	2026-07-24 14:19:44.077972+00
298	128	010466	legacy	2026-07-24 14:19:44.077972+00
299	129	Espejo DE MALETERO UNIVERSAL VARIOS CON BRAZO	legacy	2026-07-24 14:19:44.077972+00
300	129	E-PT-VAR	legacy	2026-07-24 14:19:44.077972+00
301	130	Espejo HIACE 96	legacy	2026-07-24 14:19:44.077972+00
302	130	3366	legacy	2026-07-24 14:19:44.077972+00
303	130	3366-R	legacy	2026-07-24 14:19:44.077972+00
304	131	3367-L	legacy	2026-07-24 14:19:44.077972+00
305	131	3367	legacy	2026-07-24 14:19:44.077972+00
306	131	Espejo HIACE 96 LOBO CHINO	legacy	2026-07-24 14:19:44.077972+00
307	132	E-HONDA-VAR	legacy	2026-07-24 14:19:44.077972+00
308	132	Espejo HONDA VARIOS	legacy	2026-07-24 14:19:44.077972+00
309	133	Espejo HONDA ACCORD 96 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
310	133	2787	legacy	2026-07-24 14:19:44.077972+00
311	133	2787-L	legacy	2026-07-24 14:19:44.077972+00
312	134	Espejo HONDA ACCORD 96 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
313	134	2787-R	legacy	2026-07-24 14:19:44.077972+00
314	134	2787	legacy	2026-07-24 14:19:44.077972+00
315	135	19050-R	legacy	2026-07-24 14:19:44.077972+00
316	135	19050	legacy	2026-07-24 14:19:44.077972+00
317	135	Espejo HONDA ACCORD ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
318	136	011003-L	legacy	2026-07-24 14:19:44.077972+00
319	136	Espejo HONDA EG ELEVTRICO	legacy	2026-07-24 14:19:44.077972+00
320	136	011003	legacy	2026-07-24 14:19:44.077972+00
321	137	Espejo HONDA EG ELEVTRICO 7 PINES	legacy	2026-07-24 14:19:44.077972+00
322	137	011003-R	legacy	2026-07-24 14:19:44.077972+00
323	137	011003	legacy	2026-07-24 14:19:44.077972+00
324	138	11003	legacy	2026-07-24 14:19:44.077972+00
325	138	Espejo HONDA EG MANUAL	legacy	2026-07-24 14:19:44.077972+00
326	138	11003-L	legacy	2026-07-24 14:19:44.077972+00
327	139	11003-R	legacy	2026-07-24 14:19:44.077972+00
328	139	Espejo HONDA EG MANUAL	legacy	2026-07-24 14:19:44.077972+00
329	139	11003	legacy	2026-07-24 14:19:44.077972+00
330	140	5259-L	legacy	2026-07-24 14:19:44.077972+00
331	140	Espejo HONDA EK 95 /2 PuertaS ELECTRICO 3 PINES	legacy	2026-07-24 14:19:44.077972+00
332	140	5259	legacy	2026-07-24 14:19:44.077972+00
333	141	547483	legacy	2026-07-24 14:19:44.077972+00
334	141	547483-L	legacy	2026-07-24 14:19:44.077972+00
335	141	Espejo LEVIN AE101	legacy	2026-07-24 14:19:44.077972+00
336	142	547483-R	legacy	2026-07-24 14:19:44.077972+00
337	142	547483	legacy	2026-07-24 14:19:44.077972+00
338	142	Espejo LEVIN AE101	legacy	2026-07-24 14:19:44.077972+00
339	143	Espejo TOYOTA SPRINTER ELECTRICO 3 PINES	legacy	2026-07-24 14:19:44.077972+00
340	143	4219-E3	legacy	2026-07-24 14:19:44.077972+00
341	143	4219-E3-R	legacy	2026-07-24 14:19:44.077972+00
342	144	Espejo TOYOTA SPRINTER MANUAL	legacy	2026-07-24 14:19:44.077972+00
343	144	4219	legacy	2026-07-24 14:19:44.077972+00
344	144	4219-R	legacy	2026-07-24 14:19:44.077972+00
345	145	3686-L	legacy	2026-07-24 14:19:44.077972+00
346	145	3686	legacy	2026-07-24 14:19:44.077972+00
347	145	Espejo MISTUBISHI MONTERO NEGRO	legacy	2026-07-24 14:19:44.077972+00
348	146	3686-R	legacy	2026-07-24 14:19:44.077972+00
349	146	3686	legacy	2026-07-24 14:19:44.077972+00
350	146	Espejo MISTUBISHI MONTERO NEGRO	legacy	2026-07-24 14:19:44.077972+00
351	147	MR155318-R	legacy	2026-07-24 14:19:44.077972+00
352	147	Espejo MITSIBISHI JUNIOR	legacy	2026-07-24 14:19:44.077972+00
353	147	MR155318	legacy	2026-07-24 14:19:44.077972+00
354	148	2105-L	legacy	2026-07-24 14:19:44.077972+00
355	148	Espejo MITSUBISH GRANDDIS CROMADO	legacy	2026-07-24 14:19:44.077972+00
356	148	2105	legacy	2026-07-24 14:19:44.077972+00
357	149	Espejo MITSUBISH GRANDDIS CROMADO	legacy	2026-07-24 14:19:44.077972+00
358	149	2105-R	legacy	2026-07-24 14:19:44.077972+00
359	149	2105	legacy	2026-07-24 14:19:44.077972+00
360	150	K317-R	legacy	2026-07-24 14:19:44.077972+00
361	150	K317	legacy	2026-07-24 14:19:44.077972+00
362	150	Espejo MITSUBISHI EVO 9	legacy	2026-07-24 14:19:44.077972+00
363	151	Espejo MITSUBISHI IO	legacy	2026-07-24 14:19:44.077972+00
364	151	010131	legacy	2026-07-24 14:19:44.077972+00
365	151	010131-R	legacy	2026-07-24 14:19:44.077972+00
366	152	Espejo MITSUBISHI LANCER 92	legacy	2026-07-24 14:19:44.077972+00
367	152	02-0067-L	legacy	2026-07-24 14:19:44.077972+00
368	152	02-0067	legacy	2026-07-24 14:19:44.077972+00
369	153	Espejo MITSUBISHI LANCER 92	legacy	2026-07-24 14:19:44.077972+00
370	153	02-0067-R	legacy	2026-07-24 14:19:44.077972+00
371	153	02-0067	legacy	2026-07-24 14:19:44.077972+00
372	154	5419	legacy	2026-07-24 14:19:44.077972+00
373	154	Espejo MITSUBISHI GALANT 96-98	legacy	2026-07-24 14:19:44.077972+00
374	154	5419-R	legacy	2026-07-24 14:19:44.077972+00
375	154	Espejo MITSUBISHI LANCER 99	legacy	2026-07-24 14:19:44.077972+00
376	155	Espejo MITSUBISHI MONTERO CROMADO ELECTRICO YT7230	legacy	2026-07-24 14:19:44.077972+00
377	155	3686-C-L	legacy	2026-07-24 14:19:44.077972+00
378	155	3686-C	legacy	2026-07-24 14:19:44.077972+00
379	156	Espejo MITSUBISHI MONTERO CROMADO ELECTRICO YT7230	legacy	2026-07-24 14:19:44.077972+00
380	156	3686-C	legacy	2026-07-24 14:19:44.077972+00
381	156	3686-C-R	legacy	2026-07-24 14:19:44.077972+00
382	157	0455-N	legacy	2026-07-24 14:19:44.077972+00
383	157	Espejo NISSAN AD 2002-2006 BY11 NEGRO 215-15A3	legacy	2026-07-24 14:19:44.077972+00
384	157	0455-N-L	legacy	2026-07-24 14:19:44.077972+00
385	158	0455-N	legacy	2026-07-24 14:19:44.077972+00
386	158	Espejo NISSAN AD 2002-2006 BY11 NEGRO 215-15A3	legacy	2026-07-24 14:19:44.077972+00
387	158	0455-N-R	legacy	2026-07-24 14:19:44.077972+00
388	159	3254	legacy	2026-07-24 14:19:44.077972+00
389	159	3254-L	legacy	2026-07-24 14:19:44.077972+00
390	159	Espejo NISSAN AVENIR	legacy	2026-07-24 14:19:44.077972+00
391	159	Eléctrico	legacy	2026-07-24 14:19:44.077972+00
392	160	3254	legacy	2026-07-24 14:19:44.077972+00
393	160	Espejo NISSAN AVENIR	legacy	2026-07-24 14:19:44.077972+00
394	160	3254-R	legacy	2026-07-24 14:19:44.077972+00
395	160	Eléctrico	legacy	2026-07-24 14:19:44.077972+00
396	161	4675-E-L	legacy	2026-07-24 14:19:44.077972+00
397	161	Espejo Nissan b14 corto Eléctrico 5 pines	legacy	2026-07-24 14:19:44.077972+00
398	161	4675-E	legacy	2026-07-24 14:19:44.077972+00
399	161	Espejo NISSAN B14 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
400	162	4675-E-R	legacy	2026-07-24 14:19:44.077972+00
401	162	Espejo Nissan b14 corto Eléctrico 5 pines	legacy	2026-07-24 14:19:44.077972+00
402	162	4675-E	legacy	2026-07-24 14:19:44.077972+00
403	162	Espejo NISSAN B14 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
404	163	4675	legacy	2026-07-24 14:19:44.077972+00
405	163	Espejo NISSAN B14 MANUAL	legacy	2026-07-24 14:19:44.077972+00
406	163	4675-L	legacy	2026-07-24 14:19:44.077972+00
407	164	4675	legacy	2026-07-24 14:19:44.077972+00
408	164	Espejo NISSAN B14 MANUAL	legacy	2026-07-24 14:19:44.077972+00
409	164	4675-R	legacy	2026-07-24 14:19:44.077972+00
410	165	Espejo NISSAN BONGO	legacy	2026-07-24 14:19:44.077972+00
411	165	847P	legacy	2026-07-24 14:19:44.077972+00
412	165	847P-R	legacy	2026-07-24 14:19:44.077972+00
413	166	N36-L	legacy	2026-07-24 14:19:44.077972+00
414	166	N36	legacy	2026-07-24 14:19:44.077972+00
415	166	Espejo NISSAN CHAPULIN	legacy	2026-07-24 14:19:44.077972+00
416	167	3965-L	legacy	2026-07-24 14:19:44.077972+00
417	167	3965	legacy	2026-07-24 14:19:44.077972+00
418	167	Espejo NISSAN CUSTOM	legacy	2026-07-24 14:19:44.077972+00
419	168	Espejo NISSAN MARCH 2004	legacy	2026-07-24 14:19:44.077972+00
420	168	8289-L	legacy	2026-07-24 14:19:44.077972+00
421	168	8289	legacy	2026-07-24 14:19:44.077972+00
422	169	Espejo NISSAN MARCH 2004	legacy	2026-07-24 14:19:44.077972+00
423	169	8289-R	legacy	2026-07-24 14:19:44.077972+00
424	169	8289	legacy	2026-07-24 14:19:44.077972+00
425	170	0815-L	legacy	2026-07-24 14:19:44.077972+00
426	170	Espejo NISSAN MARCH 87 / SKYLINE R32 /MICRA K10	legacy	2026-07-24 14:19:44.077972+00
427	170	Espejo SUNNY b 12 Manual	legacy	2026-07-24 14:19:44.077972+00
428	170	0815	legacy	2026-07-24 14:19:44.077972+00
429	171	Espejo NISSAN MARCH K11 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
430	171	6067-R	legacy	2026-07-24 14:19:44.077972+00
431	171	6067	legacy	2026-07-24 14:19:44.077972+00
432	172	3981	legacy	2026-07-24 14:19:44.077972+00
433	172	3981-R	legacy	2026-07-24 14:19:44.077972+00
434	172	Espejo NISSAN MARCH K11 MANUAL	legacy	2026-07-24 14:19:44.077972+00
435	173	3530-L	legacy	2026-07-24 14:19:44.077972+00
436	173	3530	legacy	2026-07-24 14:19:44.077972+00
437	173	Espejo NISSAN PRESSEA 97	legacy	2026-07-24 14:19:44.077972+00
438	174	Espejo NISSAN PULSAR 95 /BLUBIRD	legacy	2026-07-24 14:19:44.077972+00
439	174	0043	legacy	2026-07-24 14:19:44.077972+00
440	174	0043-L	legacy	2026-07-24 14:19:44.077972+00
441	175	Espejo NISSAN PULSAR 95 /BLUBIRD	legacy	2026-07-24 14:19:44.077972+00
442	175	0043	legacy	2026-07-24 14:19:44.077972+00
443	175	0043-R	legacy	2026-07-24 14:19:44.077972+00
444	176	3803	legacy	2026-07-24 14:19:44.077972+00
445	176	Espejo NISSAN SERENA	legacy	2026-07-24 14:19:44.077972+00
446	176	3803-R	legacy	2026-07-24 14:19:44.077972+00
447	177	4572	legacy	2026-07-24 14:19:44.077972+00
448	177	4572-L	legacy	2026-07-24 14:19:44.077972+00
449	177	Espejo NISSAN SKYLINE R33	legacy	2026-07-24 14:19:44.077972+00
450	178	4572	legacy	2026-07-24 14:19:44.077972+00
451	178	4572-R	legacy	2026-07-24 14:19:44.077972+00
452	178	Espejo NISSAN SKYLINE R33	legacy	2026-07-24 14:19:44.077972+00
453	179	192	legacy	2026-07-24 14:19:44.077972+00
454	179	Espejo NISSAN URBAN E23	legacy	2026-07-24 14:19:44.077972+00
455	179	192-L	legacy	2026-07-24 14:19:44.077972+00
456	180	7426	legacy	2026-07-24 14:19:44.077972+00
457	180	7426-L	legacy	2026-07-24 14:19:44.077972+00
458	180	Espejo PROBOX 98 BASE GRANDE	legacy	2026-07-24 14:19:44.077972+00
459	181	7426-R	legacy	2026-07-24 14:19:44.077972+00
460	181	7426	legacy	2026-07-24 14:19:44.077972+00
461	181	Espejo PROBOX 98 BASE GRANDE	legacy	2026-07-24 14:19:44.077972+00
462	182	Espejo RAV4 96	legacy	2026-07-24 14:19:44.077972+00
463	182	4856	legacy	2026-07-24 14:19:44.077972+00
464	182	4856-L	legacy	2026-07-24 14:19:44.077972+00
465	183	Espejo RAV4 96	legacy	2026-07-24 14:19:44.077972+00
466	183	4856	legacy	2026-07-24 14:19:44.077972+00
467	183	4856-R	legacy	2026-07-24 14:19:44.077972+00
468	184	Espejo REDONDO UNIVERSAL PEQUEÑO	legacy	2026-07-24 14:19:44.077972+00
469	184	122472-U	legacy	2026-07-24 14:19:44.077972+00
470	185	8030-L	legacy	2026-07-24 14:19:44.077972+00
471	185	Espejo RESTROVISOR TOYOTA HIACE 2008 BRAZO	legacy	2026-07-24 14:19:44.077972+00
472	185	8030	legacy	2026-07-24 14:19:44.077972+00
473	186	5277-R	legacy	2026-07-24 14:19:44.077972+00
474	186	5277	legacy	2026-07-24 14:19:44.077972+00
475	186	Espejo RETROVISOR HILUX SURF 99	legacy	2026-07-24 14:19:44.077972+00
476	187	Espejo RETROVISOR NISSAN AD 90	legacy	2026-07-24 14:19:44.077972+00
477	187	3666	legacy	2026-07-24 14:19:44.077972+00
478	187	3666-L	legacy	2026-07-24 14:19:44.077972+00
479	188	3666-R	legacy	2026-07-24 14:19:44.077972+00
480	188	Espejo RETROVISOR NISSAN AD 90	legacy	2026-07-24 14:19:44.077972+00
481	188	3666	legacy	2026-07-24 14:19:44.077972+00
482	189	5048	legacy	2026-07-24 14:19:44.077972+00
483	189	Espejo SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
484	189	5048-R	legacy	2026-07-24 14:19:44.077972+00
485	190	5092	legacy	2026-07-24 14:19:44.077972+00
486	190	5092-L	legacy	2026-07-24 14:19:44.077972+00
487	190	Espejo SUBARU IMPREZA 2000	legacy	2026-07-24 14:19:44.077972+00
488	191	Espejo SUBARU IMPREZA 2001	legacy	2026-07-24 14:19:44.077972+00
489	191	5092	legacy	2026-07-24 14:19:44.077972+00
490	191	5092-R	legacy	2026-07-24 14:19:44.077972+00
491	192	1644	legacy	2026-07-24 14:19:44.077972+00
492	192	Espejo TOWN ACE MOD 87 212-1568	legacy	2026-07-24 14:19:44.077972+00
493	192	1644-R	legacy	2026-07-24 14:19:44.077972+00
494	193	3095	legacy	2026-07-24 14:19:44.077972+00
495	193	3095-L	legacy	2026-07-24 14:19:44.077972+00
496	193	Espejo TOWN ACE MOD 87 212-1568	legacy	2026-07-24 14:19:44.077972+00
497	194	Cresta Lx80	legacy	2026-07-24 14:19:44.077972+00
498	194	8112-L	legacy	2026-07-24 14:19:44.077972+00
499	194	8112	legacy	2026-07-24 14:19:44.077972+00
500	194	Espejo TOYOTA CAMRY 1992	legacy	2026-07-24 14:19:44.077972+00
501	195	8112-R	legacy	2026-07-24 14:19:44.077972+00
502	195	Cresta Lx80	legacy	2026-07-24 14:19:44.077972+00
503	195	8112	legacy	2026-07-24 14:19:44.077972+00
504	195	Espejo TOYOTA CAMRY 1992	legacy	2026-07-24 14:19:44.077972+00
505	196	Espejo TOYOTA CAMRY 88	legacy	2026-07-24 14:19:44.077972+00
506	196	6219-L	legacy	2026-07-24 14:19:44.077972+00
507	196	6219	legacy	2026-07-24 14:19:44.077972+00
508	197	6219-R	legacy	2026-07-24 14:19:44.077972+00
509	197	Espejo TOYOTA CAMRY 88	legacy	2026-07-24 14:19:44.077972+00
510	197	6219	legacy	2026-07-24 14:19:44.077972+00
511	198	E-FX-R	legacy	2026-07-24 14:19:44.077972+00
512	198	E-FX	legacy	2026-07-24 14:19:44.077972+00
513	198	Espejo TOYOTA COROLLA FX	legacy	2026-07-24 14:19:44.077972+00
514	199	4766-L	legacy	2026-07-24 14:19:44.077972+00
515	199	Espejo TOYOTA CORONA 93	legacy	2026-07-24 14:19:44.077972+00
516	199	4766	legacy	2026-07-24 14:19:44.077972+00
517	200	3710	legacy	2026-07-24 14:19:44.077972+00
518	200	Espejo TOYOTA CORSA 90	legacy	2026-07-24 14:19:44.077972+00
519	200	3710-L	legacy	2026-07-24 14:19:44.077972+00
520	201	Espejo TOYOTA CORSA 96	legacy	2026-07-24 14:19:44.077972+00
521	201	48692-L	legacy	2026-07-24 14:19:44.077972+00
522	201	48692	legacy	2026-07-24 14:19:44.077972+00
523	202	Espejo TOYOTA CROWN	legacy	2026-07-24 14:19:44.077972+00
524	202	4453-L	legacy	2026-07-24 14:19:44.077972+00
525	202	4453	legacy	2026-07-24 14:19:44.077972+00
526	203	Espejo TOYOTA CROWN	legacy	2026-07-24 14:19:44.077972+00
527	203	4453-R	legacy	2026-07-24 14:19:44.077972+00
528	203	4453	legacy	2026-07-24 14:19:44.077972+00
529	204	5483	legacy	2026-07-24 14:19:44.077972+00
530	204	5483-L	legacy	2026-07-24 14:19:44.077972+00
531	204	Espejo TOYOTA IPSUM ELÉCTRICO	legacy	2026-07-24 14:19:44.077972+00
532	205	5483	legacy	2026-07-24 14:19:44.077972+00
533	205	5483-R	legacy	2026-07-24 14:19:44.077972+00
534	205	Espejo TOYOTA IPSUM ELÉCTRICO	legacy	2026-07-24 14:19:44.077972+00
535	206	5862-L	legacy	2026-07-24 14:19:44.077972+00
536	206	Espejo TOYOTA IPSUM	legacy	2026-07-24 14:19:44.077972+00
537	206	5862	legacy	2026-07-24 14:19:44.077972+00
538	207	5862-R	legacy	2026-07-24 14:19:44.077972+00
539	207	Espejo TOYOTA IPSUM	legacy	2026-07-24 14:19:44.077972+00
540	207	5862	legacy	2026-07-24 14:19:44.077972+00
541	208	561326-R	legacy	2026-07-24 14:19:44.077972+00
542	208	Espejo TOYOTA LEVIN TRUNO 90	legacy	2026-07-24 14:19:44.077972+00
543	208	561326	legacy	2026-07-24 14:19:44.077972+00
544	209	3009	legacy	2026-07-24 14:19:44.077972+00
545	209	3009-L	legacy	2026-07-24 14:19:44.077972+00
546	209	Espejo TOYOTA MARCK 98	legacy	2026-07-24 14:19:44.077972+00
547	210	3009	legacy	2026-07-24 14:19:44.077972+00
548	210	Espejo TOYOTA MARCK 98	legacy	2026-07-24 14:19:44.077972+00
549	210	3009-R	legacy	2026-07-24 14:19:44.077972+00
550	211	G-30	legacy	2026-07-24 14:19:44.077972+00
551	211	G-30-L	legacy	2026-07-24 14:19:44.077972+00
552	211	Espejo TOYOTA MARCK 98	legacy	2026-07-24 14:19:44.077972+00
553	212	G-30-R	legacy	2026-07-24 14:19:44.077972+00
554	212	G-30	legacy	2026-07-24 14:19:44.077972+00
555	212	Espejo TOYOTA MARCK 98	legacy	2026-07-24 14:19:44.077972+00
556	213	Espejo TOYOTA MARINO	legacy	2026-07-24 14:19:44.077972+00
557	213	4230-L	legacy	2026-07-24 14:19:44.077972+00
558	213	4230	legacy	2026-07-24 14:19:44.077972+00
559	214	5574-L	legacy	2026-07-24 14:19:44.077972+00
560	214	5574	legacy	2026-07-24 14:19:44.077972+00
561	214	Espejo TOYOTA RAV 4 MOD 99	legacy	2026-07-24 14:19:44.077972+00
562	215	5574-R	legacy	2026-07-24 14:19:44.077972+00
563	215	5574	legacy	2026-07-24 14:19:44.077972+00
564	215	Espejo TOYOTA RAV 4 MOD 99	legacy	2026-07-24 14:19:44.077972+00
565	216	5430	legacy	2026-07-24 14:19:44.077972+00
566	216	Espejo TOYOTA REFLEX	legacy	2026-07-24 14:19:44.077972+00
567	216	5430-L	legacy	2026-07-24 14:19:44.077972+00
568	217	5480-L	legacy	2026-07-24 14:19:44.077972+00
569	217	5480	legacy	2026-07-24 14:19:44.077972+00
570	217	Espejo TOYOTA SPACIO NEGRO ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
571	218	8278-L	legacy	2026-07-24 14:19:44.077972+00
572	218	Espejo TOYOTA VITZ ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
573	218	8278	legacy	2026-07-24 14:19:44.077972+00
574	219	8278-R	legacy	2026-07-24 14:19:44.077972+00
575	219	Espejo TOYOTA VITZ ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
576	219	8278	legacy	2026-07-24 14:19:44.077972+00
577	220	B38	legacy	2026-07-24 14:19:44.077972+00
578	220	Espejo URVAN E25 CON BRAZO	legacy	2026-07-24 14:19:44.077972+00
579	220	B38-L	legacy	2026-07-24 14:19:44.077972+00
580	221	1621	legacy	2026-07-24 14:19:44.077972+00
581	221	Espejo CRESSIDA	legacy	2026-07-24 14:19:44.077972+00
582	221	1621-L	legacy	2026-07-24 14:19:44.077972+00
583	222	547483-E-R	legacy	2026-07-24 14:19:44.077972+00
584	222	Espejo LEVIN 95 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
585	222	547483-E	legacy	2026-07-24 14:19:44.077972+00
586	223	464-R	legacy	2026-07-24 14:19:44.077972+00
587	223	Espejo MITSUBISHI CHALLENGER	legacy	2026-07-24 14:19:44.077972+00
588	223	464	legacy	2026-07-24 14:19:44.077972+00
589	224	8222	legacy	2026-07-24 14:19:44.077972+00
590	224	Espejo NISSAN BLUEBIRTH 91-95	legacy	2026-07-24 14:19:44.077972+00
591	224	8222-R	legacy	2026-07-24 14:19:44.077972+00
592	225	5770	legacy	2026-07-24 14:19:44.077972+00
593	225	5770-L	legacy	2026-07-24 14:19:44.077972+00
594	225	Espejo TOYOTA CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
595	226	5770	legacy	2026-07-24 14:19:44.077972+00
596	226	5770-R	legacy	2026-07-24 14:19:44.077972+00
597	226	Espejo TOYOTA CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
598	227	Espejo TOYOTA CELICA 90	legacy	2026-07-24 14:19:44.077972+00
599	227	3352-R	legacy	2026-07-24 14:19:44.077972+00
600	227	3352	legacy	2026-07-24 14:19:44.077972+00
601	228	Espejo TOYOTA CELICA 98	legacy	2026-07-24 14:19:44.077972+00
602	228	4696-R	legacy	2026-07-24 14:19:44.077972+00
603	228	4696	legacy	2026-07-24 14:19:44.077972+00
604	229	3488-2	legacy	2026-07-24 14:19:44.077972+00
605	229	3488-2-R	legacy	2026-07-24 14:19:44.077972+00
606	229	Espejo TOYOTA COROLLA 90 MANUAL	legacy	2026-07-24 14:19:44.077972+00
607	230	6658-L	legacy	2026-07-24 14:19:44.077972+00
608	230	6658	legacy	2026-07-24 14:19:44.077972+00
609	230	Espejo TOYOTA VITZ MANUAL	legacy	2026-07-24 14:19:44.077972+00
610	231	6658-R	legacy	2026-07-24 14:19:44.077972+00
611	231	6658	legacy	2026-07-24 14:19:44.077972+00
612	231	Espejo TOYOTA VITZ MANUAL	legacy	2026-07-24 14:19:44.077972+00
613	232	P38-L	legacy	2026-07-24 14:19:44.077972+00
614	232	Espejo CHANCHO	legacy	2026-07-24 14:19:44.077972+00
615	232	P38	legacy	2026-07-24 14:19:44.077972+00
616	233	Espejo TOYOTA LEVIN 95	legacy	2026-07-24 14:19:44.077972+00
617	233	561327-L	legacy	2026-07-24 14:19:44.077972+00
618	233	561327	legacy	2026-07-24 14:19:44.077972+00
619	234	8102-L	legacy	2026-07-24 14:19:44.077972+00
620	234	8102	legacy	2026-07-24 14:19:44.077972+00
621	234	Espejo CEDRICK Y31/Y30 87/89	legacy	2026-07-24 14:19:44.077972+00
622	235	8102	legacy	2026-07-24 14:19:44.077972+00
623	235	8102-R	legacy	2026-07-24 14:19:44.077972+00
624	235	Espejo CEDRICK Y31/Y30 87/89	legacy	2026-07-24 14:19:44.077972+00
625	236	0455	legacy	2026-07-24 14:19:44.077972+00
626	236	0455-L	legacy	2026-07-24 14:19:44.077972+00
627	236	Espejo NISSAN B15 PLOMO PATA LARGA	legacy	2026-07-24 14:19:44.077972+00
628	237	0455-R	legacy	2026-07-24 14:19:44.077972+00
629	237	0455	legacy	2026-07-24 14:19:44.077972+00
630	237	Espejo NISSAN B15 PLOMO PATA LARGA	legacy	2026-07-24 14:19:44.077972+00
631	238	Espejo NISSAN LARGO 97	legacy	2026-07-24 14:19:44.077972+00
632	238	4439-L	legacy	2026-07-24 14:19:44.077972+00
633	238	4439	legacy	2026-07-24 14:19:44.077972+00
634	239	Espejo NISSAN LARGO 97	legacy	2026-07-24 14:19:44.077972+00
635	239	4439-R	legacy	2026-07-24 14:19:44.077972+00
636	239	4439	legacy	2026-07-24 14:19:44.077972+00
637	240	1739-R	legacy	2026-07-24 14:19:44.077972+00
638	240	Espejo TOYOTA EP71	legacy	2026-07-24 14:19:44.077972+00
639	240	1739	legacy	2026-07-24 14:19:44.077972+00
640	241	Espejo TOYOTA LITE ACE CR40 97/2000	legacy	2026-07-24 14:19:44.077972+00
641	241	5589	legacy	2026-07-24 14:19:44.077972+00
642	241	5589-R	legacy	2026-07-24 14:19:44.077972+00
643	242	Espejo TOYOTA LOBO YT7013 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
644	242	3369	legacy	2026-07-24 14:19:44.077972+00
645	242	3369-L	legacy	2026-07-24 14:19:44.077972+00
646	243	Espejo TOYOTA LOBO YT7013 ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
647	243	3369	legacy	2026-07-24 14:19:44.077972+00
648	243	3369-R	legacy	2026-07-24 14:19:44.077972+00
649	244	542833	legacy	2026-07-24 14:19:44.077972+00
650	244	Espejo TOYOTA SUPER CRAWN	legacy	2026-07-24 14:19:44.077972+00
651	244	542833-R	legacy	2026-07-24 14:19:44.077972+00
652	245	Espejo TOYOTA SUPER CRAWN	legacy	2026-07-24 14:19:44.077972+00
653	245	542834-L	legacy	2026-07-24 14:19:44.077972+00
654	245	542834	legacy	2026-07-24 14:19:44.077972+00
655	246	Estabilizador DE IPSUM L	legacy	2026-07-24 14:19:44.077972+00
656	246	860011	legacy	2026-07-24 14:19:44.077972+00
657	247	860012	legacy	2026-07-24 14:19:44.077972+00
658	247	Estabilizador DE IPSUM R	legacy	2026-07-24 14:19:44.077972+00
659	248	Estabilizador DELANTERO DE COROOLA	legacy	2026-07-24 14:19:44.077972+00
660	248	860010	legacy	2026-07-24 14:19:44.077972+00
661	249	860119	legacy	2026-07-24 14:19:44.077972+00
662	249	Estabilizador HILUX VIGO R	legacy	2026-07-24 14:19:44.077972+00
663	250	Estabilizador HILUX VIGO TRASERO L	legacy	2026-07-24 14:19:44.077972+00
664	250	860127	legacy	2026-07-24 14:19:44.077972+00
665	251	860100	legacy	2026-07-24 14:19:44.077972+00
666	251	Estabilizador RAV4 97-2004	legacy	2026-07-24 14:19:44.077972+00
667	252	860018	legacy	2026-07-24 14:19:44.077972+00
668	252	Estabilizador XTRAIL UNIVERSAL	legacy	2026-07-24 14:19:44.077972+00
669	253	Estuche de HERRAMIENTA SUBARU	legacy	2026-07-24 14:19:44.077972+00
670	253	EH-SUBARU	legacy	2026-07-24 14:19:44.077972+00
671	254	EH-TOYOTA	legacy	2026-07-24 14:19:44.077972+00
672	254	Estuche de HERRAMIENTA TOYOTA	legacy	2026-07-24 14:19:44.077972+00
673	255	SCOOTER-MO	legacy	2026-07-24 14:19:44.077972+00
674	255	Estuche MOCHILA SCOOTER	legacy	2026-07-24 14:19:44.077972+00
675	256	12-148	legacy	2026-07-24 14:19:44.077972+00
676	256	12-148-L	legacy	2026-07-24 14:19:44.077972+00
677	256	Bisel Y Media luz 212-1203 F-KE 1972	legacy	2026-07-24 14:19:44.077972+00
678	257	Farol -SUZUKI CULTUS 218-1106	legacy	2026-07-24 14:19:44.077972+00
679	257	10-32247	legacy	2026-07-24 14:19:44.077972+00
680	257	10-32247-L	legacy	2026-07-24 14:19:44.077972+00
681	258	F-AE86-L	legacy	2026-07-24 14:19:44.077972+00
682	258	F-AE86	legacy	2026-07-24 14:19:44.077972+00
683	258	Farol AE86	legacy	2026-07-24 14:19:44.077972+00
684	259	Farol ASX Mod. 2011~2012~2013~2014	legacy	2026-07-24 14:19:44.077972+00
685	259	214-1199	legacy	2026-07-24 14:19:44.077972+00
686	259	214-1199-L	legacy	2026-07-24 14:19:44.077972+00
687	260	Farol ASX Mod. 2011~2012~2013~2014	legacy	2026-07-24 14:19:44.077972+00
688	260	214-1199	legacy	2026-07-24 14:19:44.077972+00
689	260	214-1199-R	legacy	2026-07-24 14:19:44.077972+00
690	261	100-87262	legacy	2026-07-24 14:19:44.077972+00
691	261	Farol CHARIOT GRANDIS	legacy	2026-07-24 14:19:44.077972+00
692	261	100-87262-L	legacy	2026-07-24 14:19:44.077972+00
693	262	100-87262	legacy	2026-07-24 14:19:44.077972+00
694	262	100-87262-R	legacy	2026-07-24 14:19:44.077972+00
695	262	Farol CHARIOT GRANDIS	legacy	2026-07-24 14:19:44.077972+00
696	263	16-45	legacy	2026-07-24 14:19:44.077972+00
697	263	Farol COROLLA 90 CON Guiñador	legacy	2026-07-24 14:19:44.077972+00
698	263	16-45-L	legacy	2026-07-24 14:19:44.077972+00
699	264	16-45-R	legacy	2026-07-24 14:19:44.077972+00
700	264	16-45	legacy	2026-07-24 14:19:44.077972+00
701	264	Farol COROLLA 90 CON Guiñador	legacy	2026-07-24 14:19:44.077972+00
702	265	Farol CUADRADO UNIVERSAL CON SOPORTE	legacy	2026-07-24 14:19:44.077972+00
703	265	20-90-R	legacy	2026-07-24 14:19:44.077972+00
704	265	20-90	legacy	2026-07-24 14:19:44.077972+00
705	266	24522	legacy	2026-07-24 14:19:44.077972+00
706	266	Farol CUADRADO UNIVERSAL CON SOPORTE	legacy	2026-07-24 14:19:44.077972+00
707	266	24522-R	legacy	2026-07-24 14:19:44.077972+00
708	267	110-37615	legacy	2026-07-24 14:19:44.077972+00
709	267	110-37615-L	legacy	2026-07-24 14:19:44.077972+00
710	267	Farol DELICA MITSUBISHI	legacy	2026-07-24 14:19:44.077972+00
711	268	110-37615	legacy	2026-07-24 14:19:44.077972+00
712	268	110-37615-R	legacy	2026-07-24 14:19:44.077972+00
713	268	Farol DELICA MITSUBISHI	legacy	2026-07-24 14:19:44.077972+00
714	269	Farol Fiat UNO Mod.2010~2011~2012~2013~2014~2015~2016~ NEGRO	legacy	2026-07-24 14:19:44.077972+00
715	269	661-1165-L	legacy	2026-07-24 14:19:44.077972+00
716	269	661-1165	legacy	2026-07-24 14:19:44.077972+00
717	270	661-1165-R	legacy	2026-07-24 14:19:44.077972+00
718	270	Farol Fiat UNO Mod.2010~2011~2012~2013~2014~2015~2016~ NEGRO	legacy	2026-07-24 14:19:44.077972+00
719	270	661-1165	legacy	2026-07-24 14:19:44.077972+00
720	271	K30-1162	legacy	2026-07-24 14:19:44.077972+00
721	271	K30-1162-L	legacy	2026-07-24 14:19:44.077972+00
722	271	Farol FORD MUSTANG SHELBY GT500 Mod.2014~2015~2016~2017~	legacy	2026-07-24 14:19:44.077972+00
723	272	K30-1162	legacy	2026-07-24 14:19:44.077972+00
724	272	K30-1162-R	legacy	2026-07-24 14:19:44.077972+00
725	272	Farol FORD MUSTANG SHELBY GT500 Mod.2014~2015~2016~2017~	legacy	2026-07-24 14:19:44.077972+00
726	273	Farol FORESTER 97	legacy	2026-07-24 14:19:44.077972+00
727	273	1550	legacy	2026-07-24 14:19:44.077972+00
728	273	1550-L	legacy	2026-07-24 14:19:44.077972+00
729	274	100-59079-L	legacy	2026-07-24 14:19:44.077972+00
730	274	100-59079	legacy	2026-07-24 14:19:44.077972+00
731	274	Farol GRAN VITARA 218-1135	legacy	2026-07-24 14:19:44.077972+00
732	275	100-59079-R	legacy	2026-07-24 14:19:44.077972+00
733	275	100-59079	legacy	2026-07-24 14:19:44.077972+00
734	275	Farol GRAN VITARA 218-1135	legacy	2026-07-24 14:19:44.077972+00
735	276	317-1180-L	legacy	2026-07-24 14:19:44.077972+00
736	276	317-1180	legacy	2026-07-24 14:19:44.077972+00
737	276	Farol HONDA CIVIC Mod. 2016~2017~2018 HATCHBACK COUPE SEDAN	legacy	2026-07-24 14:19:44.077972+00
738	277	Farol HONDA CIVIC Mod.92 3D-4D K600 BALLADE	legacy	2026-07-24 14:19:44.077972+00
739	277	217-1111 PXA-L	legacy	2026-07-24 14:19:44.077972+00
740	277	217-1111 PXA	legacy	2026-07-24 14:19:44.077972+00
741	278	217-1111 PXA-R	legacy	2026-07-24 14:19:44.077972+00
742	278	Farol HONDA CIVIC Mod.92 3D-4D K600 BALLADE	legacy	2026-07-24 14:19:44.077972+00
743	278	217-1111 PXA	legacy	2026-07-24 14:19:44.077972+00
744	279	001-6557	legacy	2026-07-24 14:19:44.077972+00
745	279	Farol HONDA EF	legacy	2026-07-24 14:19:44.077972+00
746	279	001-6557-R	legacy	2026-07-24 14:19:44.077972+00
747	280	221-1160-2L	legacy	2026-07-24 14:19:44.077972+00
748	280	Farol HYUNDAI ACCENT SOLARIS Mod. 2011~2012~2014	legacy	2026-07-24 14:19:44.077972+00
749	281	221-1185-L	legacy	2026-07-24 14:19:44.077972+00
750	281	221-1185	legacy	2026-07-24 14:19:44.077972+00
751	281	Farol HYUNDAI i10 GRAND i10 Mod. 2013~2014~2015~2016	legacy	2026-07-24 14:19:44.077972+00
752	282	221-1185	legacy	2026-07-24 14:19:44.077972+00
753	282	Farol HYUNDAI i10 GRAND i10 Mod. 2013~2014~2015~2016	legacy	2026-07-24 14:19:44.077972+00
754	282	221-1185-R	legacy	2026-07-24 14:19:44.077972+00
755	283	Farol i10 GRAND i10 Mod. 2011~2012	legacy	2026-07-24 14:19:44.077972+00
756	283	221-1159-L	legacy	2026-07-24 14:19:44.077972+00
757	283	221-1159	legacy	2026-07-24 14:19:44.077972+00
758	284	Farol i10 GRAND i10 Mod. 2011~2012	legacy	2026-07-24 14:19:44.077972+00
759	284	221-1159	legacy	2026-07-24 14:19:44.077972+00
760	284	221-1159-R	legacy	2026-07-24 14:19:44.077972+00
761	285	Farol JEEP GRAN CHEROKEE Mod. 2005~2006~2007	legacy	2026-07-24 14:19:44.077972+00
762	285	333-1172	legacy	2026-07-24 14:19:44.077972+00
763	285	333-1172-L	legacy	2026-07-24 14:19:44.077972+00
764	286	Farol JEEP GRAN CHEROKEE Mod. 2005~2006~2007	legacy	2026-07-24 14:19:44.077972+00
765	286	333-1172	legacy	2026-07-24 14:19:44.077972+00
766	286	333-1172-R	legacy	2026-07-24 14:19:44.077972+00
767	287	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
768	287	323-1105-L	legacy	2026-07-24 14:19:44.077972+00
769	287	323-1105	legacy	2026-07-24 14:19:44.077972+00
770	288	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
771	288	323-1105	legacy	2026-07-24 14:19:44.077972+00
772	288	323-1105-R	legacy	2026-07-24 14:19:44.077972+00
773	289	323-1501	legacy	2026-07-24 14:19:44.077972+00
774	289	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
775	289	323-1501-L	legacy	2026-07-24 14:19:44.077972+00
776	290	323-1501	legacy	2026-07-24 14:19:44.077972+00
777	290	Farol KIA SPORTAGE Mod.97~98~99~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
778	290	323-1501-R	legacy	2026-07-24 14:19:44.077972+00
779	291	Farol LANCER Mod. 2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
780	291	214-1163	legacy	2026-07-24 14:19:44.077972+00
781	291	214-1163-L	legacy	2026-07-24 14:19:44.077972+00
782	292	Farol LANCER Mod. 2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
783	292	214-1163-R	legacy	2026-07-24 14:19:44.077972+00
784	292	214-1163	legacy	2026-07-24 14:19:44.077972+00
785	293	214-1148-L	legacy	2026-07-24 14:19:44.077972+00
786	293	214-1148	legacy	2026-07-24 14:19:44.077972+00
787	293	Farol LANCER Negro Mod. 98~99~2000~2001 CK5	legacy	2026-07-24 14:19:44.077972+00
788	294	214-1148	legacy	2026-07-24 14:19:44.077972+00
789	294	214-1148-R	legacy	2026-07-24 14:19:44.077972+00
790	294	Farol LANCER Negro Mod. 98~99~2000~2001 CK5	legacy	2026-07-24 14:19:44.077972+00
791	295	12-296	legacy	2026-07-24 14:19:44.077972+00
792	295	Farol LEVIN 90	legacy	2026-07-24 14:19:44.077972+00
793	295	12-296-L	legacy	2026-07-24 14:19:44.077972+00
794	296	Farol MAZDA PICK UP BT-50 Mod.2015~2016~2017	legacy	2026-07-24 14:19:44.077972+00
795	296	216-1175	legacy	2026-07-24 14:19:44.077972+00
796	296	216-1175-L	legacy	2026-07-24 14:19:44.077972+00
797	297	Farol MAZDA PICK UP BT-50 Mod.2015~2016~2017	legacy	2026-07-24 14:19:44.077972+00
798	297	216-1175	legacy	2026-07-24 14:19:44.077972+00
799	297	216-1175-R	legacy	2026-07-24 14:19:44.077972+00
800	298	Farol Mitsubishi ECLIPSE Mod. 2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
801	298	314-1126	legacy	2026-07-24 14:19:44.077972+00
802	298	314-1126-L	legacy	2026-07-24 14:19:44.077972+00
803	299	314-1126-R	legacy	2026-07-24 14:19:44.077972+00
804	299	Farol Mitsubishi ECLIPSE Mod. 2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
805	299	314-1126	legacy	2026-07-24 14:19:44.077972+00
806	300	7524	legacy	2026-07-24 14:19:44.077972+00
807	300	Farol MITSUBISHI GALANT	legacy	2026-07-24 14:19:44.077972+00
808	300	7524-R	legacy	2026-07-24 14:19:44.077972+00
809	301	214-1159	legacy	2026-07-24 14:19:44.077972+00
810	301	Farol MONTERO TIBURON 2000~2001~2002~2003~2004~2005~2006	legacy	2026-07-24 14:19:44.077972+00
811	301	214-1159-L	legacy	2026-07-24 14:19:44.077972+00
812	302	214-1159	legacy	2026-07-24 14:19:44.077972+00
813	302	Farol MONTERO TIBURON 2000~2001~2002~2003~2004~2005~2006	legacy	2026-07-24 14:19:44.077972+00
814	302	214-1159-R	legacy	2026-07-24 14:19:44.077972+00
815	303	Farol NISSAN B13 215-1134 vidrio	legacy	2026-07-24 14:19:44.077972+00
816	303	1299-R	legacy	2026-07-24 14:19:44.077972+00
817	303	1299	legacy	2026-07-24 14:19:44.077972+00
818	304	1478	legacy	2026-07-24 14:19:44.077972+00
819	304	1478-L	legacy	2026-07-24 14:19:44.077972+00
820	304	Farol NISSAN B13 215-1154 Plastico	legacy	2026-07-24 14:19:44.077972+00
821	305	1478-R	legacy	2026-07-24 14:19:44.077972+00
822	305	1478	legacy	2026-07-24 14:19:44.077972+00
823	305	Farol NISSAN B13 215-1154 Plastico	legacy	2026-07-24 14:19:44.077972+00
824	306	1439-L	legacy	2026-07-24 14:19:44.077972+00
825	306	Farol NISSSAN CUSTUM	legacy	2026-07-24 14:19:44.077972+00
826	306	1439	legacy	2026-07-24 14:19:44.077972+00
827	307	1439-R	legacy	2026-07-24 14:19:44.077972+00
828	307	Farol NISSSAN CUSTUM	legacy	2026-07-24 14:19:44.077972+00
829	307	1439	legacy	2026-07-24 14:19:44.077972+00
830	308	553-1101-LDEM2-L	legacy	2026-07-24 14:19:44.077972+00
831	308	553-1101-LDEM2	legacy	2026-07-24 14:19:44.077972+00
832	308	Farol Renault DUSTER Mod.2013~2014~2015~2016~	legacy	2026-07-24 14:19:44.077972+00
833	309	553-1101-LDEM2-R	legacy	2026-07-24 14:19:44.077972+00
834	309	553-1101-LDEM2	legacy	2026-07-24 14:19:44.077972+00
835	309	Farol Renault DUSTER Mod.2013~2014~2015~2016~	legacy	2026-07-24 14:19:44.077972+00
836	310	551-11AK E2	legacy	2026-07-24 14:19:44.077972+00
837	310	551-11AK E2-L	legacy	2026-07-24 14:19:44.077972+00
838	310	Farol Renault KWID Mod.2017~2018~2019~2020	legacy	2026-07-24 14:19:44.077972+00
839	311	551-11AK E2	legacy	2026-07-24 14:19:44.077972+00
840	311	551-11AK E2-R	legacy	2026-07-24 14:19:44.077972+00
841	311	Farol Renault KWID Mod.2017~2018~2019~2020	legacy	2026-07-24 14:19:44.077972+00
842	312	10-66	legacy	2026-07-24 14:19:44.077972+00
843	312	Farol SRALET EP82	legacy	2026-07-24 14:19:44.077972+00
844	312	10-66-L	legacy	2026-07-24 14:19:44.077972+00
845	313	10-58-L	legacy	2026-07-24 14:19:44.077972+00
846	313	10-58	legacy	2026-07-24 14:19:44.077972+00
847	313	Farol SRALET EP82 GT 212-1152	legacy	2026-07-24 14:19:44.077972+00
848	314	Farol STARLET EP82	legacy	2026-07-24 14:19:44.077972+00
849	314	10-66-R	legacy	2026-07-24 14:19:44.077972+00
850	314	10-66	legacy	2026-07-24 14:19:44.077972+00
851	315	10-58	legacy	2026-07-24 14:19:44.077972+00
852	315	10-58-R	legacy	2026-07-24 14:19:44.077972+00
853	315	Farol STARLET EP82 GT 212-1152	legacy	2026-07-24 14:19:44.077972+00
854	316	2068	legacy	2026-07-24 14:19:44.077972+00
855	316	Farol SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
856	316	2068-L	legacy	2026-07-24 14:19:44.077972+00
857	317	2068	legacy	2026-07-24 14:19:44.077972+00
858	317	Farol SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
859	317	2068-R	legacy	2026-07-24 14:19:44.077972+00
860	318	1540-L	legacy	2026-07-24 14:19:44.077972+00
861	318	Farol SUBARU IMPREZA	legacy	2026-07-24 14:19:44.077972+00
862	318	1540	legacy	2026-07-24 14:19:44.077972+00
863	319	Farol SUBARU IMPREZA 4D~5D Mod. 97~99	legacy	2026-07-24 14:19:44.077972+00
864	319	220-1105	legacy	2026-07-24 14:19:44.077972+00
865	319	220-1105-L	legacy	2026-07-24 14:19:44.077972+00
866	320	Farol SUBARU IMPREZA 4D~5D Mod. 97~99	legacy	2026-07-24 14:19:44.077972+00
867	320	220-1105	legacy	2026-07-24 14:19:44.077972+00
868	320	220-1105-R	legacy	2026-07-24 14:19:44.077972+00
869	321	52-016-L	legacy	2026-07-24 14:19:44.077972+00
870	321	52-016	legacy	2026-07-24 14:19:44.077972+00
871	321	Farol SUCCED	legacy	2026-07-24 14:19:44.077972+00
872	322	52-016	legacy	2026-07-24 14:19:44.077972+00
873	322	52-016-R	legacy	2026-07-24 14:19:44.077972+00
874	322	Farol SUCCED	legacy	2026-07-24 14:19:44.077972+00
875	323	100-1120	legacy	2026-07-24 14:19:44.077972+00
876	323	100-1120-L	legacy	2026-07-24 14:19:44.077972+00
877	323	Farol suelto universal p/foco cambiable H4 (tipo wagner) 2000	legacy	2026-07-24 14:19:44.077972+00
878	324	100-1120-R	legacy	2026-07-24 14:19:44.077972+00
879	324	100-1120	legacy	2026-07-24 14:19:44.077972+00
880	324	Farol suelto universal p/foco cambiable H4 (tipo wagner) 2000	legacy	2026-07-24 14:19:44.077972+00
881	325	Farol suelto UNIVERSAL p/foco cambiable REDONDO CRISTAL 2000	legacy	2026-07-24 14:19:44.077972+00
882	325	100-1124-L/R	legacy	2026-07-24 14:19:44.077972+00
883	326	218-1136	legacy	2026-07-24 14:19:44.077972+00
884	326	Farol Suzuqui GRAND VITARA XL7 Mod.2005~2006~2007~2008	legacy	2026-07-24 14:19:44.077972+00
885	326	218-1136-L	legacy	2026-07-24 14:19:44.077972+00
886	327	218-1136	legacy	2026-07-24 14:19:44.077972+00
887	327	Farol Suzuqui GRAND VITARA XL7 Mod.2005~2006~2007~2008	legacy	2026-07-24 14:19:44.077972+00
888	327	218-1136-R	legacy	2026-07-24 14:19:44.077972+00
889	328	Farol Suzuqui SWIFT Mod.2017~2018~2019~2020 ECE.ELEC	legacy	2026-07-24 14:19:44.077972+00
890	328	218-1170	legacy	2026-07-24 14:19:44.077972+00
891	328	218-1170-L	legacy	2026-07-24 14:19:44.077972+00
892	329	218-1170-R	legacy	2026-07-24 14:19:44.077972+00
893	329	Farol Suzuqui SWIFT Mod.2017~2018~2019~2020 ECE.ELEC	legacy	2026-07-24 14:19:44.077972+00
894	329	218-1170	legacy	2026-07-24 14:19:44.077972+00
895	330	Farol TOYOTA CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
896	330	05-31	legacy	2026-07-24 14:19:44.077972+00
897	330	05-31-L	legacy	2026-07-24 14:19:44.077972+00
898	331	Farol TOYOTA CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
899	331	05-31-R	legacy	2026-07-24 14:19:44.077972+00
900	331	05-31	legacy	2026-07-24 14:19:44.077972+00
901	332	12-428-L	legacy	2026-07-24 14:19:44.077972+00
902	332	12-428	legacy	2026-07-24 14:19:44.077972+00
903	332	Farol TOYOTA CARIB 96	legacy	2026-07-24 14:19:44.077972+00
904	333	12-428	legacy	2026-07-24 14:19:44.077972+00
905	333	12-428-R	legacy	2026-07-24 14:19:44.077972+00
906	333	Farol TOYOTA CARIB 96	legacy	2026-07-24 14:19:44.077972+00
907	334	Farol TOYOTA CORONA 212-1105	legacy	2026-07-24 14:19:44.077972+00
908	334	20-145	legacy	2026-07-24 14:19:44.077972+00
909	334	20-145-L	legacy	2026-07-24 14:19:44.077972+00
910	335	Farol TOYOTA CORONA 212-1138	legacy	2026-07-24 14:19:44.077972+00
911	335	20-260-R	legacy	2026-07-24 14:19:44.077972+00
912	335	20-260	legacy	2026-07-24 14:19:44.077972+00
913	336	1210	legacy	2026-07-24 14:19:44.077972+00
914	336	1210-R	legacy	2026-07-24 14:19:44.077972+00
915	336	Farol TOYOTA CORONA VERIFICAR BLUE BIRD 215-1145	legacy	2026-07-24 14:19:44.077972+00
916	337	26-13	legacy	2026-07-24 14:19:44.077972+00
917	337	Farol TOYOTA CUSTOM	legacy	2026-07-24 14:19:44.077972+00
918	337	26-13-L	legacy	2026-07-24 14:19:44.077972+00
919	338	26-32	legacy	2026-07-24 14:19:44.077972+00
920	338	26-32-L	legacy	2026-07-24 14:19:44.077972+00
921	338	Farol TOYOTA CUSTOM CON Guiñador	legacy	2026-07-24 14:19:44.077972+00
922	339	26-32-R	legacy	2026-07-24 14:19:44.077972+00
923	339	Farol TOYOTA CUSTOM CON Guiñador	legacy	2026-07-24 14:19:44.077972+00
924	339	26-32	legacy	2026-07-24 14:19:44.077972+00
1259	457	Guiñador SERENA	legacy	2026-07-24 14:19:44.077972+00
925	340	Farol TOYOTA CUSTOM CUADRADO	legacy	2026-07-24 14:19:44.077972+00
926	340	26-13	legacy	2026-07-24 14:19:44.077972+00
927	340	26-13-R	legacy	2026-07-24 14:19:44.077972+00
928	341	32-22	legacy	2026-07-24 14:19:44.077972+00
929	341	Farol TOYOTA DESCONOCIDO	legacy	2026-07-24 14:19:44.077972+00
930	341	32-22-R	legacy	2026-07-24 14:19:44.077972+00
931	342	Farol TOYOTA FX	legacy	2026-07-24 14:19:44.077972+00
932	342	12-322-R	legacy	2026-07-24 14:19:44.077972+00
933	342	12-322	legacy	2026-07-24 14:19:44.077972+00
934	343	25-72	legacy	2026-07-24 14:19:44.077972+00
935	343	25-72-R	legacy	2026-07-24 14:19:44.077972+00
936	343	Farol TOYOTA REDONDO CON SOPORTE	legacy	2026-07-24 14:19:44.077972+00
937	344	Farol TRUENO 97	legacy	2026-07-24 14:19:44.077972+00
938	344	12-342	legacy	2026-07-24 14:19:44.077972+00
939	344	12-342-L	legacy	2026-07-24 14:19:44.077972+00
940	345	Farol TRUENO 97	legacy	2026-07-24 14:19:44.077972+00
941	345	12-342-R	legacy	2026-07-24 14:19:44.077972+00
942	345	12-342	legacy	2026-07-24 14:19:44.077972+00
943	346	441-1130-L	legacy	2026-07-24 14:19:44.077972+00
944	346	Farol Volkswagen GOLF IV Mod.1998~1999~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
945	346	441-1130	legacy	2026-07-24 14:19:44.077972+00
946	347	441-1130-R	legacy	2026-07-24 14:19:44.077972+00
947	347	Farol Volkswagen GOLF IV Mod.1998~1999~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
948	347	441-1130	legacy	2026-07-24 14:19:44.077972+00
949	348	C-3024075	legacy	2026-07-24 14:19:44.077972+00
950	348	Filtro	legacy	2026-07-24 14:19:44.077972+00
951	349	C-3024017	legacy	2026-07-24 14:19:44.077972+00
952	349	Filtro de AIRE 1RZ HIACE LOBO 17801-54140-C (+CHINOS)	legacy	2026-07-24 14:19:44.077972+00
953	350	C-3024084	legacy	2026-07-24 14:19:44.077972+00
954	350	Filtro de AIRE 1RZ HIACE LOBO REGIUS COMMUTER KING LONG (+CHINOS)	legacy	2026-07-24 14:19:44.077972+00
955	351	Filtro de AIRE 4A 4AG/AE100 5A COROLLA SPACIO LEVIN SPRINTER CARIB	legacy	2026-07-24 14:19:44.077972+00
956	351	C-3024001	legacy	2026-07-24 14:19:44.077972+00
957	352	Filtro de AIRE COROLLA Mod. 92 ~ 2002	legacy	2026-07-24 14:19:44.077972+00
958	352	C-3024005	legacy	2026-07-24 14:19:44.077972+00
959	353	Filtro de aire NISSAN URBAN E24 CARAVAN C/P/aspa	legacy	2026-07-24 14:19:44.077972+00
960	353	C-3024013	legacy	2026-07-24 14:19:44.077972+00
961	354	C-3024004	legacy	2026-07-24 14:19:44.077972+00
962	354	Filtro de AIRE NOAH TOWNACE TACOMA PREVIA PICKUP 4RUNNER LITEACE HILUX	legacy	2026-07-24 14:19:44.077972+00
963	355	122472	legacy	2026-07-24 14:19:44.077972+00
964	355	Filtro de AIRE SUZUQUI 13780-79210 EMP-265	legacy	2026-07-24 14:19:44.077972+00
965	356	Filtro TOYOTA HILUX VIGO 2KDFTV	legacy	2026-07-24 14:19:44.077972+00
966	356	C-3024064	legacy	2026-07-24 14:19:44.077972+00
967	357	CH-216010	legacy	2026-07-24 14:19:44.077972+00
968	357	Foco Alogeno H4 de Farol SUPER WHITE AZULADO	legacy	2026-07-24 14:19:44.077972+00
969	358	Foco CUÑA moderno de 1 contacto 12V 21W Un filamento	legacy	2026-07-24 14:19:44.077972+00
970	358	CH-216028	legacy	2026-07-24 14:19:44.077972+00
971	359	CH-216029	legacy	2026-07-24 14:19:44.077972+00
972	359	Foco CUÑA moderno de 2 contactos 12V 21/5W. #7443 T-20 Dos filamentos	legacy	2026-07-24 14:19:44.077972+00
973	360	CH-216036	legacy	2026-07-24 14:19:44.077972+00
974	360	Foco de DOBLE Contacto 12V 21/5W FP5412 Dos filamentos Universal P/Stop	legacy	2026-07-24 14:19:44.077972+00
975	361	FRONT-AD	legacy	2026-07-24 14:19:44.077972+00
976	361	Frontal NISSAN AD 2004	legacy	2026-07-24 14:19:44.077972+00
977	362	FRONT-IGNIS	legacy	2026-07-24 14:19:44.077972+00
978	362	Frontal SUZUKI SWIFT IMCOMPLETO IGNIS	legacy	2026-07-24 14:19:44.077972+00
979	363	Frontal TOYOTA CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
980	363	FRONT-CALDINAGT	legacy	2026-07-24 14:19:44.077972+00
981	364	Frontal TOYOTA NOHA BOXY	legacy	2026-07-24 14:19:44.077972+00
982	364	FRONT-BOXY	legacy	2026-07-24 14:19:44.077972+00
983	365	SUPERKOTTE-G	legacy	2026-07-24 14:19:44.077972+00
984	365	Grasa PEQUEÑA	legacy	2026-07-24 14:19:44.077972+00
985	366	Guardafango CHANCHO	legacy	2026-07-24 14:19:44.077972+00
986	366	GF-E24	legacy	2026-07-24 14:19:44.077972+00
987	366	GF-E24-L	legacy	2026-07-24 14:19:44.077972+00
988	367	Guardafango CHANCHO	legacy	2026-07-24 14:19:44.077972+00
989	367	GF-E24	legacy	2026-07-24 14:19:44.077972+00
990	367	GF-E24-R	legacy	2026-07-24 14:19:44.077972+00
991	368	Guardafango DE VITARA CON BUCHERA	legacy	2026-07-24 14:19:44.077972+00
992	368	GF-VITARA	legacy	2026-07-24 14:19:44.077972+00
993	368	GF-VITARA-L	legacy	2026-07-24 14:19:44.077972+00
994	369	Guardafango DE VITARA CON BUCHERA	legacy	2026-07-24 14:19:44.077972+00
995	369	GF-VITARA	legacy	2026-07-24 14:19:44.077972+00
996	369	GF-VITARA-R	legacy	2026-07-24 14:19:44.077972+00
997	370	12-285-L	legacy	2026-07-24 14:19:44.077972+00
998	370	Guinador COROLLA 90 212-1524	legacy	2026-07-24 14:19:44.077972+00
999	370	12-285	legacy	2026-07-24 14:19:44.077972+00
1000	371	1688-R	legacy	2026-07-24 14:19:44.077972+00
1001	371	1688	legacy	2026-07-24 14:19:44.077972+00
1260	458	2165	legacy	2026-07-24 14:19:44.077972+00
1002	371	Guinador FX ANTIGUO COROLLA 2	legacy	2026-07-24 14:19:44.077972+00
1003	372	210-37746-R	legacy	2026-07-24 14:19:44.077972+00
1004	372	Guinador PAJERO MONTERO 214-1531	legacy	2026-07-24 14:19:44.077972+00
1005	372	210-37746	legacy	2026-07-24 14:19:44.077972+00
1006	373	218-1602-L	legacy	2026-07-24 14:19:44.077972+00
1007	373	218-1602	legacy	2026-07-24 14:19:44.077972+00
1008	373	Guinador de Parachoque Suzuki Samurai	legacy	2026-07-24 14:19:44.077972+00
1009	374	218-1602-R	legacy	2026-07-24 14:19:44.077972+00
1010	374	218-1602	legacy	2026-07-24 14:19:44.077972+00
1011	374	Guinador de Parachoque Suzuki Samurai	legacy	2026-07-24 14:19:44.077972+00
1012	375	210-37779	legacy	2026-07-24 14:19:44.077972+00
1013	375	210-37779-L	legacy	2026-07-24 14:19:44.077972+00
1014	375	Guiñador ECLIPSE	legacy	2026-07-24 14:19:44.077972+00
1015	376	Guiñador AD 215-1561	legacy	2026-07-24 14:19:44.077972+00
1016	376	3313-R	legacy	2026-07-24 14:19:44.077972+00
1017	376	3313	legacy	2026-07-24 14:19:44.077972+00
1018	377	Guiñador CALDIN GT	legacy	2026-07-24 14:19:44.077972+00
1019	377	05-32	legacy	2026-07-24 14:19:44.077972+00
1020	377	05-32-L	legacy	2026-07-24 14:19:44.077972+00
1021	378	05-32	legacy	2026-07-24 14:19:44.077972+00
1022	378	Guiñador CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
1023	378	05-32-R	legacy	2026-07-24 14:19:44.077972+00
1024	379	20-317	legacy	2026-07-24 14:19:44.077972+00
1025	379	Guiñador CARINA AE 91	legacy	2026-07-24 14:19:44.077972+00
1026	379	20-317-R	legacy	2026-07-24 14:19:44.077972+00
1027	380	20-383	legacy	2026-07-24 14:19:44.077972+00
1028	380	Guiñador CARINA CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
1029	380	20-383-L	legacy	2026-07-24 14:19:44.077972+00
1030	381	20-383-R	legacy	2026-07-24 14:19:44.077972+00
1031	381	Guiñador CARINA CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
1032	381	20-383	legacy	2026-07-24 14:19:44.077972+00
1033	382	20-262-R	legacy	2026-07-24 14:19:44.077972+00
1034	382	Guiñador CARINA PUNTA REDONDA	legacy	2026-07-24 14:19:44.077972+00
1035	382	20-262	legacy	2026-07-24 14:19:44.077972+00
1036	383	20-197	legacy	2026-07-24 14:19:44.077972+00
1037	383	Guiñador CARINA PUNTA REDONDA 212-1543	legacy	2026-07-24 14:19:44.077972+00
1038	383	20-197-L	legacy	2026-07-24 14:19:44.077972+00
1039	384	20-197	legacy	2026-07-24 14:19:44.077972+00
1040	384	Guiñador CARINA PUNTA REDONDA 212-1543	legacy	2026-07-24 14:19:44.077972+00
1041	384	20-197-R	legacy	2026-07-24 14:19:44.077972+00
1042	385	Guiñador CARINA PUNTA REDONDA 212-1557	legacy	2026-07-24 14:19:44.077972+00
1043	385	20-262	legacy	2026-07-24 14:19:44.077972+00
1044	385	20-262-L	legacy	2026-07-24 14:19:44.077972+00
1045	386	Guiñador CERES	legacy	2026-07-24 14:19:44.077972+00
1046	386	12-372	legacy	2026-07-24 14:19:44.077972+00
1047	386	12-372-L	legacy	2026-07-24 14:19:44.077972+00
1048	387	12-372-R	legacy	2026-07-24 14:19:44.077972+00
1049	387	Guiñador CERES	legacy	2026-07-24 14:19:44.077972+00
1050	387	12-372	legacy	2026-07-24 14:19:44.077972+00
1051	388	120-87194-L	legacy	2026-07-24 14:19:44.077972+00
1052	388	Guiñador CHALLENGER	legacy	2026-07-24 14:19:44.077972+00
1053	388	120-87194	legacy	2026-07-24 14:19:44.077972+00
1054	389	120-87194-R	legacy	2026-07-24 14:19:44.077972+00
1055	389	Guiñador CHALLENGER	legacy	2026-07-24 14:19:44.077972+00
1056	389	120-87194	legacy	2026-07-24 14:19:44.077972+00
1057	390	16-96	legacy	2026-07-24 14:19:44.077972+00
1058	390	16-96-L	legacy	2026-07-24 14:19:44.077972+00
1059	390	Guiñador COROLLA 2	legacy	2026-07-24 14:19:44.077972+00
1060	391	16-96-R	legacy	2026-07-24 14:19:44.077972+00
1061	391	16-96	legacy	2026-07-24 14:19:44.077972+00
1062	391	Guiñador COROLLA 2	legacy	2026-07-24 14:19:44.077972+00
1063	392	Guiñador COROLLA 84 212-1611	legacy	2026-07-24 14:19:44.077972+00
1064	392	12-197-L	legacy	2026-07-24 14:19:44.077972+00
1065	392	12-197	legacy	2026-07-24 14:19:44.077972+00
1066	393	Guiñador COROLLA 84 212-1611	legacy	2026-07-24 14:19:44.077972+00
1067	393	12-197	legacy	2026-07-24 14:19:44.077972+00
1068	393	12-197-R	legacy	2026-07-24 14:19:44.077972+00
1069	394	12-412	legacy	2026-07-24 14:19:44.077972+00
1070	394	Guiñador COROLLA SAPITO 212-1592	legacy	2026-07-24 14:19:44.077972+00
1071	394	12-412-R	legacy	2026-07-24 14:19:44.077972+00
1072	395	Guiñador CORONA 212-1605	legacy	2026-07-24 14:19:44.077972+00
1073	395	1469	legacy	2026-07-24 14:19:44.077972+00
1074	395	1469-R	legacy	2026-07-24 14:19:44.077972+00
1075	396	120-24580	legacy	2026-07-24 14:19:44.077972+00
1076	396	120-24580-L	legacy	2026-07-24 14:19:44.077972+00
1077	396	Guiñador CUSTOM BLANCO 215-1575	legacy	2026-07-24 14:19:44.077972+00
1078	397	120-24580-R	legacy	2026-07-24 14:19:44.077972+00
1079	397	120-24580	legacy	2026-07-24 14:19:44.077972+00
1080	397	Guiñador CUSTOM BLANCO 215-1575	legacy	2026-07-24 14:19:44.077972+00
1081	398	Guiñador DE CALDINA NARANJA	legacy	2026-07-24 14:19:44.077972+00
1082	398	20-306	legacy	2026-07-24 14:19:44.077972+00
1083	398	20-306-L	legacy	2026-07-24 14:19:44.077972+00
1084	399	Guiñador DE IMPREZA JAPONES	legacy	2026-07-24 14:19:44.077972+00
1085	399	3336-L	legacy	2026-07-24 14:19:44.077972+00
1086	399	3336	legacy	2026-07-24 14:19:44.077972+00
1087	400	312-1634PXA-L	legacy	2026-07-24 14:19:44.077972+00
1088	400	312-1634PXA	legacy	2026-07-24 14:19:44.077972+00
1424	529	MB-CALDINA	legacy	2026-07-24 14:19:44.077972+00
1089	400	Guiñador de Parachoque CELICA 90/93 TUNNIG	legacy	2026-07-24 14:19:44.077972+00
1090	401	312-1634PXA	legacy	2026-07-24 14:19:44.077972+00
1091	401	312-1634PXA-R	legacy	2026-07-24 14:19:44.077972+00
1092	401	Guiñador de Parachoque CELICA 90/93 TUNNIG	legacy	2026-07-24 14:19:44.077972+00
1093	402	26-33-L	legacy	2026-07-24 14:19:44.077972+00
1094	402	26-33	legacy	2026-07-24 14:19:44.077972+00
1095	402	Guiñador DE Parachoque DE HICE 212-1664	legacy	2026-07-24 14:19:44.077972+00
1096	403	26-33	legacy	2026-07-24 14:19:44.077972+00
1097	403	26-33-R	legacy	2026-07-24 14:19:44.077972+00
1098	403	Guiñador DE Parachoque DE HICE 212-1664	legacy	2026-07-24 14:19:44.077972+00
1099	404	Guiñador DE Parachoque DOMINGO	legacy	2026-07-24 14:19:44.077972+00
1100	404	3353-L	legacy	2026-07-24 14:19:44.077972+00
1101	404	3353	legacy	2026-07-24 14:19:44.077972+00
1102	405	3353-R	legacy	2026-07-24 14:19:44.077972+00
1103	405	Guiñador DE Parachoque DOMINGO	legacy	2026-07-24 14:19:44.077972+00
1104	405	3353	legacy	2026-07-24 14:19:44.077972+00
1105	406	Guiñador de Parachoque HONDA CIVIC CRX M.90~91 SMOKE TUNNIG Par	legacy	2026-07-24 14:19:44.077972+00
1106	406	317-1612-PTB-VS	legacy	2026-07-24 14:19:44.077972+00
1107	407	317-1603-L	legacy	2026-07-24 14:19:44.077972+00
1108	407	Guiñador de Parachoque HONDA CIVIC Mod.88~91	legacy	2026-07-24 14:19:44.077972+00
1109	407	317-1603	legacy	2026-07-24 14:19:44.077972+00
1110	408	317-1603	legacy	2026-07-24 14:19:44.077972+00
1111	408	Guiñador de Parachoque HONDA CIVIC Mod.88~91	legacy	2026-07-24 14:19:44.077972+00
1112	408	317-1603-R	legacy	2026-07-24 14:19:44.077972+00
1113	409	3382-L	legacy	2026-07-24 14:19:44.077972+00
1114	409	3382	legacy	2026-07-24 14:19:44.077972+00
1115	409	Guiñador DE Parachoque JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1116	410	3382-R	legacy	2026-07-24 14:19:44.077972+00
1117	410	3382	legacy	2026-07-24 14:19:44.077972+00
1118	410	Guiñador DE Parachoque JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1119	411	217-1608-R	legacy	2026-07-24 14:19:44.077972+00
1120	411	Guiñador de Parachoque ONDA CIVIC 88/90 3D NARANJA	legacy	2026-07-24 14:19:44.077972+00
1121	411	217-1608	legacy	2026-07-24 14:19:44.077972+00
1122	412	Guiñador de Parachoque ONDA CIVIC 88/90 3D NARANJA	legacy	2026-07-24 14:19:44.077972+00
1123	412	218-1135-R	legacy	2026-07-24 14:19:44.077972+00
1124	412	218-1135	legacy	2026-07-24 14:19:44.077972+00
1125	413	220-1608 pxa-L	legacy	2026-07-24 14:19:44.077972+00
1126	413	220-1608 pxa	legacy	2026-07-24 14:19:44.077972+00
1127	413	Guiñador de Parachoque SUBARU IMPREZA Mod.99~2000	legacy	2026-07-24 14:19:44.077972+00
1128	414	220-1608 pxa-R	legacy	2026-07-24 14:19:44.077972+00
1129	414	220-1608 pxa	legacy	2026-07-24 14:19:44.077972+00
1130	414	Guiñador de Parachoque SUBARU IMPREZA Mod.99~2000	legacy	2026-07-24 14:19:44.077972+00
1131	415	016-8319-R	legacy	2026-07-24 14:19:44.077972+00
1132	415	Guiñador DE Parachoque TRASERO CHARIOT	legacy	2026-07-24 14:19:44.077972+00
1133	415	016-8319	legacy	2026-07-24 14:19:44.077972+00
1134	416	016-8319	legacy	2026-07-24 14:19:44.077972+00
1135	416	Guiñador DE Parachoque TRASERO CHARIOT RVR	legacy	2026-07-24 14:19:44.077972+00
1136	416	016-8319-L	legacy	2026-07-24 14:19:44.077972+00
1137	417	3568-C-L	legacy	2026-07-24 14:19:44.077972+00
1138	417	Guiñador DE SURF BLANCO	legacy	2026-07-24 14:19:44.077972+00
1139	417	3568-C	legacy	2026-07-24 14:19:44.077972+00
1140	418	3568-C	legacy	2026-07-24 14:19:44.077972+00
1141	418	Guiñador DE SURF BLANCO	legacy	2026-07-24 14:19:44.077972+00
1142	418	3568-C-R	legacy	2026-07-24 14:19:44.077972+00
1143	419	2165	legacy	2026-07-24 14:19:44.077972+00
1144	419	Guiñador DOMINGO	legacy	2026-07-24 14:19:44.077972+00
1145	419	2165-R	legacy	2026-07-24 14:19:44.077972+00
1146	420	10-76	legacy	2026-07-24 14:19:44.077972+00
1147	420	Guiñador EP 82 212-1586	legacy	2026-07-24 14:19:44.077972+00
1148	420	10-76-L	legacy	2026-07-24 14:19:44.077972+00
1149	421	10-76-R	legacy	2026-07-24 14:19:44.077972+00
1150	421	Guiñador EP 82 212-15A0	legacy	2026-07-24 14:19:44.077972+00
1151	421	10-76	legacy	2026-07-24 14:19:44.077972+00
1152	422	Guiñador EP 82 212-1582	legacy	2026-07-24 14:19:44.077972+00
1153	422	10-64-L	legacy	2026-07-24 14:19:44.077972+00
1154	422	10-64	legacy	2026-07-24 14:19:44.077972+00
1155	423	Guiñador EP 82 212-1582	legacy	2026-07-24 14:19:44.077972+00
1156	423	10-64-R	legacy	2026-07-24 14:19:44.077972+00
1157	423	10-64	legacy	2026-07-24 14:19:44.077972+00
1158	424	10-67-L	legacy	2026-07-24 14:19:44.077972+00
1159	424	10-67	legacy	2026-07-24 14:19:44.077972+00
1160	424	Guiñador EP 82 212-1586	legacy	2026-07-24 14:19:44.077972+00
1161	425	Guiñador EP 82 212-15A0	legacy	2026-07-24 14:19:44.077972+00
1162	425	10-67	legacy	2026-07-24 14:19:44.077972+00
1163	425	10-67-R	legacy	2026-07-24 14:19:44.077972+00
1164	426	Guiñador HILUX 212-1539	legacy	2026-07-24 14:19:44.077972+00
1165	426	35-43-L	legacy	2026-07-24 14:19:44.077972+00
1166	426	35-43	legacy	2026-07-24 14:19:44.077972+00
1167	427	Guiñador HILUX 212-1539	legacy	2026-07-24 14:19:44.077972+00
1168	427	35-43-R	legacy	2026-07-24 14:19:44.077972+00
1169	427	35-43	legacy	2026-07-24 14:19:44.077972+00
1170	428	21-35-L	legacy	2026-07-24 14:19:44.077972+00
1171	428	21-35	legacy	2026-07-24 14:19:44.077972+00
1172	428	Guiñador LATERAL CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
1173	429	21-35-R	legacy	2026-07-24 14:19:44.077972+00
1174	429	21-35	legacy	2026-07-24 14:19:44.077972+00
1175	429	Guiñador LATERAL CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
1176	430	36401-8500	legacy	2026-07-24 14:19:44.077972+00
1177	430	36401-8500-L	legacy	2026-07-24 14:19:44.077972+00
1178	430	Guiñador LATERAL CARRY	legacy	2026-07-24 14:19:44.077972+00
1179	431	36401-8500	legacy	2026-07-24 14:19:44.077972+00
1180	431	36401-8500-R	legacy	2026-07-24 14:19:44.077972+00
1181	431	Guiñador LATERAL CARRY	legacy	2026-07-24 14:19:44.077972+00
1182	432	2155	legacy	2026-07-24 14:19:44.077972+00
1183	432	Guiñador LATERAL FORESTER 97-2000	legacy	2026-07-24 14:19:44.077972+00
1184	432	2155-L	legacy	2026-07-24 14:19:44.077972+00
1185	433	2155-R	legacy	2026-07-24 14:19:44.077972+00
1186	433	Guiñador LATERAL FORESTER 97-2000	legacy	2026-07-24 14:19:44.077972+00
1187	433	2155	legacy	2026-07-24 14:19:44.077972+00
1188	434	3162-L	legacy	2026-07-24 14:19:44.077972+00
1189	434	Guiñador lateral RAV 4 Mod. 97 ~ 2000 212-1409	legacy	2026-07-24 14:19:44.077972+00
1190	434	3162	legacy	2026-07-24 14:19:44.077972+00
1191	435	Guiñador lateral RAV 4 Mod. 97 ~ 2000 212-1409	legacy	2026-07-24 14:19:44.077972+00
1192	435	3162	legacy	2026-07-24 14:19:44.077972+00
1193	435	3162-R	legacy	2026-07-24 14:19:44.077972+00
1194	436	2175-L	legacy	2026-07-24 14:19:44.077972+00
1195	436	Guiñador LATERAL SUBARU IMPREZA	legacy	2026-07-24 14:19:44.077972+00
1196	436	2175	legacy	2026-07-24 14:19:44.077972+00
1197	437	2175-R	legacy	2026-07-24 14:19:44.077972+00
1198	437	Guiñador LATERAL SUBARU IMPREZA	legacy	2026-07-24 14:19:44.077972+00
1199	437	2175	legacy	2026-07-24 14:19:44.077972+00
1200	438	1132-215	legacy	2026-07-24 14:19:44.077972+00
1201	438	Guiñador LATERLA LANCER 92	legacy	2026-07-24 14:19:44.077972+00
1202	438	1132-215-L	legacy	2026-07-24 14:19:44.077972+00
1203	439	1132-215-R	legacy	2026-07-24 14:19:44.077972+00
1204	439	1132-215	legacy	2026-07-24 14:19:44.077972+00
1205	439	Guiñador LATERLA LANCER 92	legacy	2026-07-24 14:19:44.077972+00
1206	440	Guiñador LEVIN 96	legacy	2026-07-24 14:19:44.077972+00
1207	440	12-422-L	legacy	2026-07-24 14:19:44.077972+00
1208	440	12-422	legacy	2026-07-24 14:19:44.077972+00
1209	441	Guiñador LEVIN 96	legacy	2026-07-24 14:19:44.077972+00
1210	441	12-422-R	legacy	2026-07-24 14:19:44.077972+00
1211	441	12-422	legacy	2026-07-24 14:19:44.077972+00
1212	442	210-87233	legacy	2026-07-24 14:19:44.077972+00
1213	442	210-87233-L	legacy	2026-07-24 14:19:44.077972+00
1214	442	Guiñador MONTERO	legacy	2026-07-24 14:19:44.077972+00
1215	443	210-87233	legacy	2026-07-24 14:19:44.077972+00
1216	443	Guiñador MONTERO	legacy	2026-07-24 14:19:44.077972+00
1217	443	210-87233-R	legacy	2026-07-24 14:19:44.077972+00
1218	444	3337	legacy	2026-07-24 14:19:44.077972+00
1219	444	3337-L	legacy	2026-07-24 14:19:44.077972+00
1220	444	Guiñador NISSAN ATLAS 215-1571	legacy	2026-07-24 14:19:44.077972+00
1221	445	3337	legacy	2026-07-24 14:19:44.077972+00
1222	445	3337-R	legacy	2026-07-24 14:19:44.077972+00
1223	445	Guiñador NISSAN ATLAS 215-1571	legacy	2026-07-24 14:19:44.077972+00
1224	446	3226	legacy	2026-07-24 14:19:44.077972+00
1225	446	3226-L	legacy	2026-07-24 14:19:44.077972+00
1226	446	Guiñador NISSAN CUSTOM 315-1616	legacy	2026-07-24 14:19:44.077972+00
1227	447	3226	legacy	2026-07-24 14:19:44.077972+00
1228	447	3226-R	legacy	2026-07-24 14:19:44.077972+00
1229	447	Guiñador NISSAN CUSTOM 315-1616	legacy	2026-07-24 14:19:44.077972+00
1230	448	Guiñador NISSAN SUNNY B12 NARANJA	legacy	2026-07-24 14:19:44.077972+00
1231	448	5183-L	legacy	2026-07-24 14:19:44.077972+00
1232	448	5183	legacy	2026-07-24 14:19:44.077972+00
1233	449	Guiñador NISSAN SUNNY B12 NARANJA	legacy	2026-07-24 14:19:44.077972+00
1234	449	5183	legacy	2026-07-24 14:19:44.077972+00
1235	449	5183-R	legacy	2026-07-24 14:19:44.077972+00
1236	450	3311-L	legacy	2026-07-24 14:19:44.077972+00
1237	450	Guiñador NISSAN SUNNY B13 215-1542	legacy	2026-07-24 14:19:44.077972+00
1238	450	3311	legacy	2026-07-24 14:19:44.077972+00
1239	451	Guiñador NISSAN SUNNY B13 215-1542	legacy	2026-07-24 14:19:44.077972+00
1240	451	3311-R	legacy	2026-07-24 14:19:44.077972+00
1241	451	3311	legacy	2026-07-24 14:19:44.077972+00
1242	452	Guiñador NISSAN SUNNY B13 215-1562	legacy	2026-07-24 14:19:44.077972+00
1243	452	3339-L	legacy	2026-07-24 14:19:44.077972+00
1244	452	3339	legacy	2026-07-24 14:19:44.077972+00
1245	453	Guiñador NISSAN SUNNY B13 215-1562	legacy	2026-07-24 14:19:44.077972+00
1246	453	3339-R	legacy	2026-07-24 14:19:44.077972+00
1247	453	3339	legacy	2026-07-24 14:19:44.077972+00
1248	454	210-63317	legacy	2026-07-24 14:19:44.077972+00
1249	454	210-63317-R	legacy	2026-07-24 14:19:44.077972+00
1250	454	Guiñador PRIMERA	legacy	2026-07-24 14:19:44.077972+00
1251	455	Guiñador REFLEX EP 91 212-15A1-C	legacy	2026-07-24 14:19:44.077972+00
1252	455	10-83	legacy	2026-07-24 14:19:44.077972+00
1253	455	10-83-L	legacy	2026-07-24 14:19:44.077972+00
1254	456	Guiñador REFLEX EP 91 212-15A1-C	legacy	2026-07-24 14:19:44.077972+00
1255	456	10-83	legacy	2026-07-24 14:19:44.077972+00
1256	456	10-83-R	legacy	2026-07-24 14:19:44.077972+00
1257	457	9206-L	legacy	2026-07-24 14:19:44.077972+00
1258	457	9206	legacy	2026-07-24 14:19:44.077972+00
1261	458	Guiñador SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
1262	458	2165-L	legacy	2026-07-24 14:19:44.077972+00
1263	459	220-1402-PXA-2	legacy	2026-07-24 14:19:44.077972+00
1264	459	220-1402-PXA-2-L	legacy	2026-07-24 14:19:44.077972+00
1265	459	Guiñador Subaru FORESTER Mod. 98~2005 USA LED Negro. PAR	legacy	2026-07-24 14:19:44.077972+00
1266	460	220-1402-PXA-2-R	legacy	2026-07-24 14:19:44.077972+00
1267	460	220-1402-PXA-2	legacy	2026-07-24 14:19:44.077972+00
1268	460	Guiñador Subaru FORESTER Mod. 98~2005 USA LED Negro. PAR	legacy	2026-07-24 14:19:44.077972+00
1269	461	3200-L	legacy	2026-07-24 14:19:44.077972+00
1270	461	Guiñador SUNNY B11 BLANCO	legacy	2026-07-24 14:19:44.077972+00
1271	461	3200	legacy	2026-07-24 14:19:44.077972+00
1272	462	3200-R	legacy	2026-07-24 14:19:44.077972+00
1273	462	Guiñador SUNNY B11 BLANCO	legacy	2026-07-24 14:19:44.077972+00
1274	462	3200	legacy	2026-07-24 14:19:44.077972+00
1275	463	35-52-L	legacy	2026-07-24 14:19:44.077972+00
1276	463	35-52	legacy	2026-07-24 14:19:44.077972+00
1277	463	Guiñador SURF AMARILLO 212-1573	legacy	2026-07-24 14:19:44.077972+00
1278	464	3568-Y	legacy	2026-07-24 14:19:44.077972+00
1279	464	Guiñador SURFNARANJA	legacy	2026-07-24 14:19:44.077972+00
1280	464	3568-Y-L	legacy	2026-07-24 14:19:44.077972+00
1281	465	3568-Y	legacy	2026-07-24 14:19:44.077972+00
1282	465	Guiñador SURFNARANJA	legacy	2026-07-24 14:19:44.077972+00
1283	465	3568-Y-R	legacy	2026-07-24 14:19:44.077972+00
1284	466	Guiñador SUZUKI MARUTI 218-1503	legacy	2026-07-24 14:19:44.077972+00
1285	466	5127-L	legacy	2026-07-24 14:19:44.077972+00
1286	466	5127	legacy	2026-07-24 14:19:44.077972+00
1287	467	28-37-R	legacy	2026-07-24 14:19:44.077972+00
1288	467	28-37	legacy	2026-07-24 14:19:44.077972+00
1289	467	Guiñador TONACE	legacy	2026-07-24 14:19:44.077972+00
1290	468	Guiñador TOYOTA CUSTOM LARGO	legacy	2026-07-24 14:19:44.077972+00
1291	468	26-34	legacy	2026-07-24 14:19:44.077972+00
1292	468	26-34-L	legacy	2026-07-24 14:19:44.077972+00
1293	469	12-291	legacy	2026-07-24 14:19:44.077972+00
1294	469	Guiñador TOYOTA FX	legacy	2026-07-24 14:19:44.077972+00
1295	469	12-291-R	legacy	2026-07-24 14:19:44.077972+00
1296	470	28-74	legacy	2026-07-24 14:19:44.077972+00
1297	470	Guinador LITEACE CUSTOM 212-1568-Y	legacy	2026-07-24 14:19:44.077972+00
1298	470	28-74-L	legacy	2026-07-24 14:19:44.077972+00
1299	471	12-324-L	legacy	2026-07-24 14:19:44.077972+00
1300	471	12-324	legacy	2026-07-24 14:19:44.077972+00
1301	471	Guinador COROLLA 90 212-1647	legacy	2026-07-24 14:19:44.077972+00
1302	472	12-324-R	legacy	2026-07-24 14:19:44.077972+00
1303	472	12-324	legacy	2026-07-24 14:19:44.077972+00
1304	472	Guinador COROLLA 90 212-1647	legacy	2026-07-24 14:19:44.077972+00
1305	473	Guinador CORON EN PUNTA	legacy	2026-07-24 14:19:44.077972+00
1306	473	20-271	legacy	2026-07-24 14:19:44.077972+00
1307	473	20-271-L	legacy	2026-07-24 14:19:44.077972+00
1308	474	Guinador CORON EN PUNTA	legacy	2026-07-24 14:19:44.077972+00
1309	474	20-271-R	legacy	2026-07-24 14:19:44.077972+00
1310	474	20-271	legacy	2026-07-24 14:19:44.077972+00
1311	475	Guardafango MONTERO 90	legacy	2026-07-24 14:19:44.077972+00
1312	475	GF-MONTERO90-L	legacy	2026-07-24 14:19:44.077972+00
1313	475	GF-MONTERO90	legacy	2026-07-24 14:19:44.077972+00
1314	476	Guardafango MONTERO 90	legacy	2026-07-24 14:19:44.077972+00
1315	476	GF-MONTERO90-R	legacy	2026-07-24 14:19:44.077972+00
1316	476	GF-MONTERO90	legacy	2026-07-24 14:19:44.077972+00
1317	477	JAL-M-VAR	legacy	2026-07-24 14:19:44.077972+00
1318	477	Jalador DE MANO VARIOS	legacy	2026-07-24 14:19:44.077972+00
1319	478	Jalador SUBARU DE Puerta DELANTERA	legacy	2026-07-24 14:19:44.077972+00
1320	478	PPE-PA	legacy	2026-07-24 14:19:44.077972+00
1321	479	850032	legacy	2026-07-24 14:19:44.077972+00
1322	479	Junta 20*35*23 AE100	legacy	2026-07-24 14:19:44.077972+00
1323	480	850027	legacy	2026-07-24 14:19:44.077972+00
1324	480	Junta IPSUM COROLLA Mod 87~95 24 X56X 26 C/ABS 133221	legacy	2026-07-24 14:19:44.077972+00
1325	481	Junta PATHFINDER PICK UP 6 Cyl. Mod 89~97 28 X50X 27	legacy	2026-07-24 14:19:44.077972+00
1326	481	123229	legacy	2026-07-24 14:19:44.077972+00
1327	482	Llanta SCOOTER VERDE	legacy	2026-07-24 14:19:44.077972+00
1328	482	SCOOTER-LL	legacy	2026-07-24 14:19:44.077972+00
1329	483	LP-VAR	legacy	2026-07-24 14:19:44.077972+00
1330	483	Luz DE PLACA VARIOS NEGRO	legacy	2026-07-24 14:19:44.077972+00
1331	484	13-19	legacy	2026-07-24 14:19:44.077972+00
1332	484	Luz DE RETRO HILUX SURF 92	legacy	2026-07-24 14:19:44.077972+00
1333	485	PH8A	legacy	2026-07-24 14:19:44.077972+00
1334	485	Filtro de ACEITE 3/4 X 16 PH8-TH8A. C-3024087	legacy	2026-07-24 14:19:44.077972+00
1335	486	PH966	legacy	2026-07-24 14:19:44.077972+00
1336	486	Filtro de ACEITE PH-966B 3/4 X16 PH-201A. C-3024086	legacy	2026-07-24 14:19:44.077972+00
1337	487	Maletera CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
1338	487	MA-CALDINAGT	legacy	2026-07-24 14:19:44.077972+00
1339	488	Maletera CARIB 98	legacy	2026-07-24 14:19:44.077972+00
1340	488	MA-CARIB98	legacy	2026-07-24 14:19:44.077972+00
1341	489	Maletera COMPLETA EVOLUCION 6	legacy	2026-07-24 14:19:44.077972+00
1342	489	MA-EVO6	legacy	2026-07-24 14:19:44.077972+00
1343	490	MA-CHARIOT	legacy	2026-07-24 14:19:44.077972+00
1586	588	860071	legacy	2026-07-24 14:19:44.077972+00
1344	490	Maletera MITSUBISHI CHARIOT GRANDIS	legacy	2026-07-24 14:19:44.077972+00
1345	491	MA-IMPREZA	legacy	2026-07-24 14:19:44.077972+00
1346	491	Maletera SUBARU WAGON IMPREZA	legacy	2026-07-24 14:19:44.077972+00
1347	492	Maletera TOYOTA CALDINA A MUELLE	legacy	2026-07-24 14:19:44.077972+00
1348	492	MA-CALDINA	legacy	2026-07-24 14:19:44.077972+00
1349	493	MA-VITARA	legacy	2026-07-24 14:19:44.077972+00
1350	493	Maletera Suzuki vitara A MUELLE	legacy	2026-07-24 14:19:44.077972+00
1351	494	MA-IPSUM	legacy	2026-07-24 14:19:44.077972+00
1352	494	Maletera TOYOTA IPSUM 96	legacy	2026-07-24 14:19:44.077972+00
1353	495	Maletera NISSAN CARAVAN CHANCHO	legacy	2026-07-24 14:19:44.077972+00
1354	495	MA-CHAN	legacy	2026-07-24 14:19:44.077972+00
1355	496	Maletera SUBARU FORESTER 2000	legacy	2026-07-24 14:19:44.077972+00
1356	496	MA-FORESTER2000	legacy	2026-07-24 14:19:44.077972+00
1357	497	Mascara A VENIR AD 96 VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
1358	497	62310-70N00	legacy	2026-07-24 14:19:44.077972+00
1359	498	Mascara ATRAIL Blanco	legacy	2026-07-24 14:19:44.077972+00
1360	498	53111-97503	legacy	2026-07-24 14:19:44.077972+00
1361	499	Mascara CARIB	legacy	2026-07-24 14:19:44.077972+00
1362	499	53111-13120	legacy	2026-07-24 14:19:44.077972+00
1363	500	M-CARINA-C	legacy	2026-07-24 14:19:44.077972+00
1364	500	Mascara CARINA 85 CROMADO	legacy	2026-07-24 14:19:44.077972+00
1365	501	M-CARINA-B	legacy	2026-07-24 14:19:44.077972+00
1366	501	Mascara CARINA 85 NEGRO	legacy	2026-07-24 14:19:44.077972+00
1367	502	Mascara CARINA 89	legacy	2026-07-24 14:19:44.077972+00
1368	502	53101-20340	legacy	2026-07-24 14:19:44.077972+00
1369	503	Mascara TOYOTA HIACE CUSTOM 92	legacy	2026-07-24 14:19:44.077972+00
1370	503	53111-95J02	legacy	2026-07-24 14:19:44.077972+00
1371	504	62310-VE000	legacy	2026-07-24 14:19:44.077972+00
1372	504	Mascara CARAVAN K20 CROMADO	legacy	2026-07-24 14:19:44.077972+00
1373	505	Mascara CUSTOM CROMADO GUIADOR LARGO	legacy	2026-07-24 14:19:44.077972+00
1374	505	53111-95J25	legacy	2026-07-24 14:19:44.077972+00
1375	506	62310-38N10	legacy	2026-07-24 14:19:44.077972+00
1376	506	Mascara CUSTUM CROMADO CON NEGRO 215-1575	legacy	2026-07-24 14:19:44.077972+00
1377	507	Mascara DS07050GA SUNNY B11	legacy	2026-07-24 14:19:44.077972+00
1378	507	DS07050GA-U	legacy	2026-07-24 14:19:44.077972+00
1379	508	55101-26020	legacy	2026-07-24 14:19:44.077972+00
1380	508	Mascara GRAN VIA 98	legacy	2026-07-24 14:19:44.077972+00
1381	509	Mascara HIACE CUSTOM 89 212-1221 TY07081GA	legacy	2026-07-24 14:19:44.077972+00
1382	509	53100-95J09	legacy	2026-07-24 14:19:44.077972+00
1383	510	Mascara HIACE Mod 85/89 minibus TY07081GA TONG YANG	legacy	2026-07-24 14:19:44.077972+00
1384	510	TY07081GA	legacy	2026-07-24 14:19:44.077972+00
1385	511	53114-12060	legacy	2026-07-24 14:19:44.077972+00
1386	511	Mascara LEVIN AE 86	legacy	2026-07-24 14:19:44.077972+00
1387	512	53111-1A140	legacy	2026-07-24 14:19:44.077972+00
1388	512	Mascara MARINO TOYOTA	legacy	2026-07-24 14:19:44.077972+00
1389	513	Mascara MITSUBISHI MONTERO NEGRO	legacy	2026-07-24 14:19:44.077972+00
1390	513	MB645720	legacy	2026-07-24 14:19:44.077972+00
1391	514	Mascara NISSAN MARCH	legacy	2026-07-24 14:19:44.077972+00
1392	514	63320-K74151	legacy	2026-07-24 14:19:44.077972+00
1393	514	63320-K74151-L	legacy	2026-07-24 14:19:44.077972+00
1394	515	63330-K74151	legacy	2026-07-24 14:19:44.077972+00
1395	515	63330-K74151-R	legacy	2026-07-24 14:19:44.077972+00
1396	515	Mascara NISSAN MARCH	legacy	2026-07-24 14:19:44.077972+00
1397	516	53111-88110	legacy	2026-07-24 14:19:44.077972+00
1398	516	Mascara STOUT TY07023	legacy	2026-07-24 14:19:44.077972+00
1399	517	Mascara SUZUKI SAMURAI	legacy	2026-07-24 14:19:44.077972+00
1400	517	72111-51010	legacy	2026-07-24 14:19:44.077972+00
1401	518	53101-13011-TW	legacy	2026-07-24 14:19:44.077972+00
1402	518	Mascara TOYOTA 212-1228 CE-96	legacy	2026-07-24 14:19:44.077972+00
1403	519	53101-20200	legacy	2026-07-24 14:19:44.077972+00
1404	519	Mascara TOYOTA CARIN A	legacy	2026-07-24 14:19:44.077972+00
1405	520	Mascara TOYOTA ESTARLET	legacy	2026-07-24 14:19:44.077972+00
1406	520	10300-0310	legacy	2026-07-24 14:19:44.077972+00
1407	521	Mascara TOYOTA HIACE 212-1196	legacy	2026-07-24 14:19:44.077972+00
1408	521	TY-2001	legacy	2026-07-24 14:19:44.077972+00
1409	522	Mascara URVAN E25 215-11A5	legacy	2026-07-24 14:19:44.077972+00
1410	522	62310-VW100	legacy	2026-07-24 14:19:44.077972+00
1411	523	Mascara URVAN TYG	legacy	2026-07-24 14:19:44.077972+00
1412	523	DS07117GA	legacy	2026-07-24 14:19:44.077972+00
1413	524	Mascara VARIOS	legacy	2026-07-24 14:19:44.077972+00
1414	524	MASC-VAR	legacy	2026-07-24 14:19:44.077972+00
1415	525	Mascara VITARA VRS AMERICANA	legacy	2026-07-24 14:19:44.077972+00
1416	525	72111-77E00	legacy	2026-07-24 14:19:44.077972+00
1417	526	53101-52060	legacy	2026-07-24 14:19:44.077972+00
1418	526	Mascara VITZ	legacy	2026-07-24 14:19:44.077972+00
1419	527	Mascara CUSTOM NISSAN CROMADO 215-1575	legacy	2026-07-24 14:19:44.077972+00
1420	527	62310-38N00	legacy	2026-07-24 14:19:44.077972+00
1421	528	Mascara DATSUN DOBLE Farol REDONDO	legacy	2026-07-24 14:19:44.077972+00
1422	528	M-DATSUN	legacy	2026-07-24 14:19:44.077972+00
1423	529	Mataburro Caldina 98	legacy	2026-07-24 14:19:44.077972+00
1425	530	Mataburro MONTERO 90	legacy	2026-07-24 14:19:44.077972+00
1426	530	MB-MONTERO	legacy	2026-07-24 14:19:44.077972+00
1427	531	PP-T10	legacy	2026-07-24 14:19:44.077972+00
1428	531	Mataburro PLASTICO SURF	legacy	2026-07-24 14:19:44.077972+00
1429	532	3320	legacy	2026-07-24 14:19:44.077972+00
1430	532	3320-L	legacy	2026-07-24 14:19:44.077972+00
1431	532	Media luz BONGO NARANJA	legacy	2026-07-24 14:19:44.077972+00
1432	533	3320	legacy	2026-07-24 14:19:44.077972+00
1433	533	3320-R	legacy	2026-07-24 14:19:44.077972+00
1434	533	Media luz BONGO NARANJA	legacy	2026-07-24 14:19:44.077972+00
1435	534	212-1611-L	legacy	2026-07-24 14:19:44.077972+00
1436	534	212-1611	legacy	2026-07-24 14:19:44.077972+00
1437	534	Media luz c/Guiñador COROLLA Mod. 84~85~86	legacy	2026-07-24 14:19:44.077972+00
1438	535	212-1611-R	legacy	2026-07-24 14:19:44.077972+00
1439	535	212-1611	legacy	2026-07-24 14:19:44.077972+00
1440	535	Media luz c/Guiñador COROLLA Mod. 84~85~86	legacy	2026-07-24 14:19:44.077972+00
1441	536	212-1561-K	legacy	2026-07-24 14:19:44.077972+00
1442	536	Media luz COROLLA Mod.92~93~94~95	legacy	2026-07-24 14:19:44.077972+00
1443	536	212-1561-K-L	legacy	2026-07-24 14:19:44.077972+00
1444	537	212-1561-K-R	legacy	2026-07-24 14:19:44.077972+00
1445	537	212-1561-K	legacy	2026-07-24 14:19:44.077972+00
1446	537	Media luz COROLLA Mod.92~93~94~95	legacy	2026-07-24 14:19:44.077972+00
1447	538	212-15D8-K	legacy	2026-07-24 14:19:44.077972+00
1448	538	Media luz COROLLA Mod.92~99	legacy	2026-07-24 14:19:44.077972+00
1449	538	212-15D8-K-L	legacy	2026-07-24 14:19:44.077972+00
1450	539	212-15D8-K	legacy	2026-07-24 14:19:44.077972+00
1451	539	212-15D8-K-R	legacy	2026-07-24 14:19:44.077972+00
1452	539	Media luz COROLLA Mod.92~99	legacy	2026-07-24 14:19:44.077972+00
1453	540	32-41	legacy	2026-07-24 14:19:44.077972+00
1454	540	Media luz DESCONOCIDO	legacy	2026-07-24 14:19:44.077972+00
1455	540	32-41-L	legacy	2026-07-24 14:19:44.077972+00
1456	541	214-1515-C	legacy	2026-07-24 14:19:44.077972+00
1457	541	214-1515-C-R	legacy	2026-07-24 14:19:44.077972+00
1458	541	Media luz GALANT Mod.89~90~91~92~93 E33A	legacy	2026-07-24 14:19:44.077972+00
1459	542	214-1515-CY-L	legacy	2026-07-24 14:19:44.077972+00
1460	542	Media luz GALANT Mod.89~90~91~92~93 E33A	legacy	2026-07-24 14:19:44.077972+00
1461	542	214-1515-CY	legacy	2026-07-24 14:19:44.077972+00
1462	543	214-1515-CY-R	legacy	2026-07-24 14:19:44.077972+00
1463	543	Media luz GALANT Mod.89~90~91~92~93 E33A	legacy	2026-07-24 14:19:44.077972+00
1464	543	214-1515-CY	legacy	2026-07-24 14:19:44.077972+00
1465	544	Media luz HIACE CUSTOM 96-2000	legacy	2026-07-24 14:19:44.077972+00
1466	544	26-37-L	legacy	2026-07-24 14:19:44.077972+00
1467	544	26-37	legacy	2026-07-24 14:19:44.077972+00
1468	545	Media luz HIACE CUSTOM 96-2000	legacy	2026-07-24 14:19:44.077972+00
1469	545	26-37	legacy	2026-07-24 14:19:44.077972+00
1470	545	26-37-R	legacy	2026-07-24 14:19:44.077972+00
1471	546	217-1519	legacy	2026-07-24 14:19:44.077972+00
1472	546	217-1519-L	legacy	2026-07-24 14:19:44.077972+00
1473	546	Media luz HONDA ACCORD Mod.90~91	legacy	2026-07-24 14:19:44.077972+00
1474	547	Media luz HONDA CIVIC 217-1520	legacy	2026-07-24 14:19:44.077972+00
1475	547	045-3966	legacy	2026-07-24 14:19:44.077972+00
1476	547	045-3966-L	legacy	2026-07-24 14:19:44.077972+00
1477	548	Media luz HONDA CIVIC 217-1520	legacy	2026-07-24 14:19:44.077972+00
1478	548	045-3966-R	legacy	2026-07-24 14:19:44.077972+00
1479	548	045-3966	legacy	2026-07-24 14:19:44.077972+00
1480	549	Media luz HONDA CIVIC Mod.90 3D	legacy	2026-07-24 14:19:44.077972+00
1481	549	217-1522	legacy	2026-07-24 14:19:44.077972+00
1482	549	217-1522-L	legacy	2026-07-24 14:19:44.077972+00
1483	550	Media luz HONDA CIVIC Mod.90 3D	legacy	2026-07-24 14:19:44.077972+00
1484	550	217-1522-R	legacy	2026-07-24 14:19:44.077972+00
1485	550	217-1522	legacy	2026-07-24 14:19:44.077972+00
1486	551	317-1522	legacy	2026-07-24 14:19:44.077972+00
1487	551	317-1522-L	legacy	2026-07-24 14:19:44.077972+00
1488	551	Media luz HONDA PRELUDE Mod. 92 ~ 96	legacy	2026-07-24 14:19:44.077972+00
1489	552	317-1522	legacy	2026-07-24 14:19:44.077972+00
1490	552	Media luz HONDA PRELUDE Mod. 92 ~ 96	legacy	2026-07-24 14:19:44.077972+00
1491	552	317-1522-R	legacy	2026-07-24 14:19:44.077972+00
1492	553	Media luz LANCER Mod. 93~94~95~96 NEGRO	legacy	2026-07-24 14:19:44.077972+00
1493	553	214-1529-PXA-2-L	legacy	2026-07-24 14:19:44.077972+00
1494	553	214-1529-PXA-2	legacy	2026-07-24 14:19:44.077972+00
1495	554	Media luz LANCER Mod. 93~94~95~96 NEGRO	legacy	2026-07-24 14:19:44.077972+00
1496	554	214-1529-PXA-2	legacy	2026-07-24 14:19:44.077972+00
1497	554	214-1529-PXA-2-R	legacy	2026-07-24 14:19:44.077972+00
1498	555	P0371	legacy	2026-07-24 14:19:44.077972+00
1499	555	Media luz MAZDA BONGO Mod.2000~2001~2002 VANETTE E2000 216-1555	legacy	2026-07-24 14:19:44.077972+00
1500	555	P0371-L	legacy	2026-07-24 14:19:44.077972+00
1501	556	Media luz MAZDA BONGO Mod.2000~2001~2002 VANETTE E2000 216-1555	legacy	2026-07-24 14:19:44.077972+00
1502	556	P0371	legacy	2026-07-24 14:19:44.077972+00
1503	556	P0371-R	legacy	2026-07-24 14:19:44.077972+00
1504	557	18-1800-R	legacy	2026-07-24 14:19:44.077972+00
1505	557	18-1800	legacy	2026-07-24 14:19:44.077972+00
2283	844	836	legacy	2026-07-24 14:19:44.077972+00
1506	557	Media luz MITSIBISHI VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
1507	558	5726-L	legacy	2026-07-24 14:19:44.077972+00
1508	558	5726	legacy	2026-07-24 14:19:44.077972+00
1509	558	Media luz MITSIBISHI VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
1510	559	215-1552	legacy	2026-07-24 14:19:44.077972+00
1511	559	Media luz Nissan BLUE BIRD Mod. 90-93(Auto)	legacy	2026-07-24 14:19:44.077972+00
1512	559	215-1552-L	legacy	2026-07-24 14:19:44.077972+00
1513	560	215-1552	legacy	2026-07-24 14:19:44.077972+00
1514	560	215-1552-R	legacy	2026-07-24 14:19:44.077972+00
1515	560	Media luz Nissan BLUE BIRD Mod. 90-93(Auto)	legacy	2026-07-24 14:19:44.077972+00
1516	561	120-63437	legacy	2026-07-24 14:19:44.077972+00
1517	561	120-63437-L	legacy	2026-07-24 14:19:44.077972+00
1518	561	Media luz PATHFINDER REGULOS	legacy	2026-07-24 14:19:44.077972+00
1519	562	120-63437	legacy	2026-07-24 14:19:44.077972+00
1520	562	Media luz PATHFINDER REGULOS	legacy	2026-07-24 14:19:44.077972+00
1521	562	120-63437-R	legacy	2026-07-24 14:19:44.077972+00
1522	563	Media luz PRESEA VERIFICAR BLUE BIRD	legacy	2026-07-24 14:19:44.077972+00
1523	563	3429	legacy	2026-07-24 14:19:44.077972+00
1524	563	3429-L	legacy	2026-07-24 14:19:44.077972+00
1525	564	Media luz PRESEA VERIFICAR BLUE BIRD	legacy	2026-07-24 14:19:44.077972+00
1526	564	3429	legacy	2026-07-24 14:19:44.077972+00
1527	564	3429-R	legacy	2026-07-24 14:19:44.077972+00
1528	565	Media luz SUNNY B11	legacy	2026-07-24 14:19:44.077972+00
1529	565	212-63141-L	legacy	2026-07-24 14:19:44.077972+00
1530	565	212-63141	legacy	2026-07-24 14:19:44.077972+00
1531	566	Media luz SUZUKI SWIF VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
1532	566	212-32284-R	legacy	2026-07-24 14:19:44.077972+00
1533	566	212-32284	legacy	2026-07-24 14:19:44.077972+00
1534	567	Media luz TOWN ACE 78	legacy	2026-07-24 14:19:44.077972+00
1535	567	28-77	legacy	2026-07-24 14:19:44.077972+00
1536	567	28-77-R	legacy	2026-07-24 14:19:44.077972+00
1537	568	Media luz TOWN ACE 78	legacy	2026-07-24 14:19:44.077972+00
1538	568	28-77	legacy	2026-07-24 14:19:44.077972+00
1539	568	28-77-L	legacy	2026-07-24 14:19:44.077972+00
1540	569	Media luz Toyota 4RUNNER Mod. 96	legacy	2026-07-24 14:19:44.077972+00
1541	569	312-1521	legacy	2026-07-24 14:19:44.077972+00
1542	569	312-1521-L	legacy	2026-07-24 14:19:44.077972+00
1543	570	Media luz Toyota 4RUNNER Mod. 96	legacy	2026-07-24 14:19:44.077972+00
1544	570	312-1521	legacy	2026-07-24 14:19:44.077972+00
1545	570	312-1521-R	legacy	2026-07-24 14:19:44.077972+00
1546	571	212-1616-R	legacy	2026-07-24 14:19:44.077972+00
1547	571	Media luz Toyota HIACE Mod.84~89	legacy	2026-07-24 14:19:44.077972+00
1548	571	212-1616	legacy	2026-07-24 14:19:44.077972+00
1549	572	Media luz Toyota HIACE Mod.90~02	legacy	2026-07-24 14:19:44.077972+00
1550	572	212-1549	legacy	2026-07-24 14:19:44.077972+00
1551	572	212-1549-R	legacy	2026-07-24 14:19:44.077972+00
1552	573	Media luz TOYOTA LITE ACE 212-1516 MOD 82	legacy	2026-07-24 14:19:44.077972+00
1553	573	28-79-L	legacy	2026-07-24 14:19:44.077972+00
1554	573	28-79	legacy	2026-07-24 14:19:44.077972+00
1555	574	Media luz TOYOTA LITE ACE 212-1516 MOD 82	legacy	2026-07-24 14:19:44.077972+00
1556	574	28-79	legacy	2026-07-24 14:19:44.077972+00
1557	574	28-79-R	legacy	2026-07-24 14:19:44.077972+00
1558	575	Media luz Toyota NOAH Mod.96~97~98 212-15H2-K	legacy	2026-07-24 14:19:44.077972+00
1559	575	28-112	legacy	2026-07-24 14:19:44.077972+00
1560	575	28-112-R	legacy	2026-07-24 14:19:44.077972+00
1561	576	860067	legacy	2026-07-24 14:19:44.077972+00
1562	576	Muñón de dirección / Terminal YOITOKI. SE-2651	legacy	2026-07-24 14:19:44.077972+00
1563	577	MD-VARIOS	legacy	2026-07-24 14:19:44.077972+00
1564	577	Muñon DE DIRECCION VARIOS	legacy	2026-07-24 14:19:44.077972+00
1565	578	Muñon de Estabilizador ilizador RUNNER YOITOKI Universal	legacy	2026-07-24 14:19:44.077972+00
1566	578	860019	legacy	2026-07-24 14:19:44.077972+00
1567	579	MS-VARIOS	legacy	2026-07-24 14:19:44.077972+00
1568	579	Muñon DE SUSPENCION VARIOS	legacy	2026-07-24 14:19:44.077972+00
1569	580	Muñon de suspensión NOAH ~ LITEACE Superior YOITOKI Sin grasera blindado	legacy	2026-07-24 14:19:44.077972+00
1570	580	860057	legacy	2026-07-24 14:19:44.077972+00
1571	581	860062	legacy	2026-07-24 14:19:44.077972+00
1572	581	Muñon de suspension VANETTE BONGO Superior 00-06	legacy	2026-07-24 14:19:44.077972+00
1573	582	Muñon DIRECCION 124848	legacy	2026-07-24 14:19:44.077972+00
1574	582	860070	legacy	2026-07-24 14:19:44.077972+00
1575	583	Muñon DIRECCION CALDINA R	legacy	2026-07-24 14:19:44.077972+00
1576	583	860069	legacy	2026-07-24 14:19:44.077972+00
1577	584	Muñon DIRECCION COROLLA 78	legacy	2026-07-24 14:19:44.077972+00
1578	584	23521	legacy	2026-07-24 14:19:44.077972+00
1579	585	Muñon DIRECCION HIACE CHINO ROSCA 15	legacy	2026-07-24 14:19:44.077972+00
1580	585	860090	legacy	2026-07-24 14:19:44.077972+00
1581	586	Muñon DIRECCION HIACE CUADRADO /HILUX 89	legacy	2026-07-24 14:19:44.077972+00
1582	586	124848	legacy	2026-07-24 14:19:44.077972+00
1583	587	Muñon DIRECCION HIACE ROSCA 15	legacy	2026-07-24 14:19:44.077972+00
1584	587	ALICMD-002	legacy	2026-07-24 14:19:44.077972+00
1585	588	Muñon DIRECCION LOBO ROSCA 17	legacy	2026-07-24 14:19:44.077972+00
1587	589	860129	legacy	2026-07-24 14:19:44.077972+00
1588	589	Muñon DIRECCION LUCIDA	legacy	2026-07-24 14:19:44.077972+00
1589	590	Muñon DIRECCION NISSAN LUCIDA	legacy	2026-07-24 14:19:44.077972+00
1590	590	860128	legacy	2026-07-24 14:19:44.077972+00
1591	591	Muñon DIRECCION PROBOX	legacy	2026-07-24 14:19:44.077972+00
1592	591	860073	legacy	2026-07-24 14:19:44.077972+00
1593	592	Muñon DIRECCION SUZUKI SX4 SWIFT	legacy	2026-07-24 14:19:44.077972+00
1594	592	860142	legacy	2026-07-24 14:19:44.077972+00
1595	593	Muñon Estabilizador largo NOAH SUZUKI	legacy	2026-07-24 14:19:44.077972+00
1596	593	860027	legacy	2026-07-24 14:19:44.077972+00
1597	594	860101	legacy	2026-07-24 14:19:44.077972+00
1598	594	Muñon Estabilizador PROBOX	legacy	2026-07-24 14:19:44.077972+00
1599	595	R-KEYTON	legacy	2026-07-24 14:19:44.077972+00
1600	595	Muñon KEYTON	legacy	2026-07-24 14:19:44.077972+00
1601	596	860143	legacy	2026-07-24 14:19:44.077972+00
1602	596	Muñon KING LONG	legacy	2026-07-24 14:19:44.077972+00
1603	597	Muñon Muñon RUNNER	legacy	2026-07-24 14:19:44.077972+00
1604	597	860121	legacy	2026-07-24 14:19:44.077972+00
1605	598	860144	legacy	2026-07-24 14:19:44.077972+00
1606	598	Muñon SIRECCION KING LONG ROSCA 14	legacy	2026-07-24 14:19:44.077972+00
1607	599	860043	legacy	2026-07-24 14:19:44.077972+00
1608	599	Muñon SUSPENCIO HIACE INFERIOR	legacy	2026-07-24 14:19:44.077972+00
1609	600	Muñon SUSPENCION NISSAN CHANCHO	legacy	2026-07-24 14:19:44.077972+00
1610	600	860060	legacy	2026-07-24 14:19:44.077972+00
1611	601	Muñon SUSPENO DEL PROBOX	legacy	2026-07-24 14:19:44.077972+00
1612	601	860048	legacy	2026-07-24 14:19:44.077972+00
1613	602	860039	legacy	2026-07-24 14:19:44.077972+00
1614	602	Muñon SUSPENSIÓN CALDINA 97	legacy	2026-07-24 14:19:44.077972+00
1615	603	860037	legacy	2026-07-24 14:19:44.077972+00
1616	603	Muñon SUSPENSIÓN COROLLA 90 L	legacy	2026-07-24 14:19:44.077972+00
1617	604	Muñon SUSPENSIÓN COROLLA 90 R	legacy	2026-07-24 14:19:44.077972+00
1618	604	860036	legacy	2026-07-24 14:19:44.077972+00
1619	605	860064	legacy	2026-07-24 14:19:44.077972+00
1620	605	Muñon SUSPENSION HIACE CUADRADO	legacy	2026-07-24 14:19:44.077972+00
1621	606	Muñon SUSPENSIÓN HIALUX 92 SUPERIOR MARCA BIG	legacy	2026-07-24 14:19:44.077972+00
1622	606	43350-39125	legacy	2026-07-24 14:19:44.077972+00
1623	607	860047	legacy	2026-07-24 14:19:44.077972+00
1624	607	Muñon SUSPENSIÓN INFERIOR NOAH LITE ACE	legacy	2026-07-24 14:19:44.077972+00
1625	608	Muñon SUSPENSIÓN LAND CRUISER	legacy	2026-07-24 14:19:44.077972+00
1626	608	43310-39016	legacy	2026-07-24 14:19:44.077972+00
1627	609	Muñon SUSPENSIÓN MINIBUS URVAN 90 ABAJO	legacy	2026-07-24 14:19:44.077972+00
1628	609	860041	legacy	2026-07-24 14:19:44.077972+00
1629	610	Muñon SUSPENSIÓN MINIUS NISSAN URVAN 90	legacy	2026-07-24 14:19:44.077972+00
1630	610	860042	legacy	2026-07-24 14:19:44.077972+00
1631	611	860046	legacy	2026-07-24 14:19:44.077972+00
1632	611	Muñon SUSPENSIÓN RAV 4	legacy	2026-07-24 14:19:44.077972+00
1633	612	43330-39245-INF	legacy	2026-07-24 14:19:44.077972+00
1634	612	Muñon TOYOTA HILUX STOUT INFERIOR	legacy	2026-07-24 14:19:44.077972+00
1635	613	43330-39245-SUP	legacy	2026-07-24 14:19:44.077972+00
1636	613	Muñon TOYOTA HILUX STOUT SUPERIOR	legacy	2026-07-24 14:19:44.077972+00
1637	614	MuñonES SUSPENSIÓN PROBOX ISQUIERDO	legacy	2026-07-24 14:19:44.077972+00
1638	614	860072	legacy	2026-07-24 14:19:44.077972+00
1639	615	8109-L	legacy	2026-07-24 14:19:44.077972+00
1640	615	RETROVISOR NISSAN SKYLINE R32	legacy	2026-07-24 14:19:44.077972+00
1641	615	8109	legacy	2026-07-24 14:19:44.077972+00
1642	616	8109-R	legacy	2026-07-24 14:19:44.077972+00
1643	616	RETROVISOR NISSAN SKYLINE R32	legacy	2026-07-24 14:19:44.077972+00
1644	616	8109	legacy	2026-07-24 14:19:44.077972+00
1645	617	N26	legacy	2026-07-24 14:19:44.077972+00
1646	617	Retrovisor Nissan Silvina 513	legacy	2026-07-24 14:19:44.077972+00
1647	617	N26-L	legacy	2026-07-24 14:19:44.077972+00
1648	618	Parachoque CARINA VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
1649	618	223604	legacy	2026-07-24 14:19:44.077972+00
1650	619	52119-1E500	legacy	2026-07-24 14:19:44.077972+00
1651	619	Parachoque COROLLA 98 SALOM	legacy	2026-07-24 14:19:44.077972+00
1652	620	71711-85D30	legacy	2026-07-24 14:19:44.077972+00
1653	620	Parachoque DEL GRAN VITARA 99 SZ04050BA	legacy	2026-07-24 14:19:44.077972+00
1654	621	Parachoque DEL HILUX 93 METALICO 212-1638	legacy	2026-07-24 14:19:44.077972+00
1655	621	52103-89110	legacy	2026-07-24 14:19:44.077972+00
1656	622	Parachoque DEL MITSUBISHI IO	legacy	2026-07-24 14:19:44.077972+00
1657	622	PD-IO	legacy	2026-07-24 14:19:44.077972+00
1658	623	6202238N00	legacy	2026-07-24 14:19:44.077972+00
1659	623	Parachoque DEL NISSAN CUSTOM NA20 ( BLANCO / PLOMO)	legacy	2026-07-24 14:19:44.077972+00
1660	624	Parachoque DEL NISSAN SUNNY B14 ( VERDE / BLANCO )	legacy	2026-07-24 14:19:44.077972+00
1661	624	62022-0M001	legacy	2026-07-24 14:19:44.077972+00
1662	625	PD-JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1663	625	Parachoque DEL PAJERO JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1664	626	PD-STARLET92	legacy	2026-07-24 14:19:44.077972+00
1665	626	Parachoque DEL STARLET PLOMO CON Alogeno	legacy	2026-07-24 14:19:44.077972+00
1666	627	Parachoque DEL SUZUKI VITARA ESCUDO ( 3 PuertaS ) TYG	legacy	2026-07-24 14:19:44.077972+00
1667	627	SZ04011BA	legacy	2026-07-24 14:19:44.077972+00
1668	628	Parachoque DEL TOYOTA CALDINA GT / CON Alogeno	legacy	2026-07-24 14:19:44.077972+00
1669	628	52119-21020	legacy	2026-07-24 14:19:44.077972+00
1670	629	Parachoque DEL TOYOTA LEVIN 96	legacy	2026-07-24 14:19:44.077972+00
1671	629	T10-TS0P	legacy	2026-07-24 14:19:44.077972+00
1672	630	Parachoque DELANTERO CORSA	legacy	2026-07-24 14:19:44.077972+00
1673	630	52119-16280	legacy	2026-07-24 14:19:44.077972+00
1674	631	Parachoque SUBARU FORESTER DELANTERO	legacy	2026-07-24 14:19:44.077972+00
1675	631	GG119-00010	legacy	2026-07-24 14:19:44.077972+00
1676	632	PT-CALDINA	legacy	2026-07-24 14:19:44.077972+00
1677	632	Parachoque TRAS CON SPOILER TOYOTA CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
1678	633	Parachoque TRAS EP82 GT	legacy	2026-07-24 14:19:44.077972+00
1679	633	PT-STARLET92	legacy	2026-07-24 14:19:44.077972+00
1680	634	PT-FORESTER	legacy	2026-07-24 14:19:44.077972+00
1681	634	Parachoque TRAS FORESTER 97	legacy	2026-07-24 14:19:44.077972+00
1682	635	50221	legacy	2026-07-24 14:19:44.077972+00
1683	635	Parachoque TRAS MAZDA BONGO	legacy	2026-07-24 14:19:44.077972+00
1684	636	PT-JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1685	636	Parachoque TRAS MITSUBISHI JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1686	637	Parachoque TRAS NISSAN CARAVAN K20 CHANCHO	legacy	2026-07-24 14:19:44.077972+00
1687	637	PT-E25	legacy	2026-07-24 14:19:44.077972+00
1688	638	Parachoque TRAS TOYOTA COROLLA 90 SEDAN	legacy	2026-07-24 14:19:44.077972+00
1689	638	PT-AE91	legacy	2026-07-24 14:19:44.077972+00
1690	639	PT-EVO6-F	legacy	2026-07-24 14:19:44.077972+00
1691	639	Parachoque TRASERO EVO 6 FIBRA	legacy	2026-07-24 14:19:44.077972+00
1692	640	PT-FORESTER2000	legacy	2026-07-24 14:19:44.077972+00
1693	640	Parachoque TRASERO FORESTER 2000	legacy	2026-07-24 14:19:44.077972+00
1694	641	Parachoque TRASERO SURF 96 3 PIEZAS	legacy	2026-07-24 14:19:44.077972+00
1695	641	PT-SURF96	legacy	2026-07-24 14:19:44.077972+00
1696	642	Parachoque DEL SURF HILUX METALICO 96 TY40165	legacy	2026-07-24 14:19:44.077972+00
1697	642	PD-SURF96	legacy	2026-07-24 14:19:44.077972+00
1698	643	PD-ESCUDO	legacy	2026-07-24 14:19:44.077972+00
1699	643	Parachoque DEL SUZUKI VITARA ESCUDO FIBRA	legacy	2026-07-24 14:19:44.077972+00
1700	644	Pastilla DE FRENO NAKHATAM SUABRU STI	legacy	2026-07-24 14:19:44.077972+00
1701	644	C-3072014	legacy	2026-07-24 14:19:44.077972+00
1702	645	Pastilla DE SUBARU FRENO	legacy	2026-07-24 14:19:44.077972+00
1703	645	C-3072001	legacy	2026-07-24 14:19:44.077972+00
1704	646	Perno barra estabilizador Turinng Mod. 97~98~99~ Largo TERRANO	legacy	2026-07-24 14:19:44.077972+00
1705	646	860024	legacy	2026-07-24 14:19:44.077972+00
1706	647	C-3024086	legacy	2026-07-24 14:19:44.077972+00
1707	647	Filtro de ACEITE 15601-33020 -TH2825 - PH2825	legacy	2026-07-24 14:19:44.077972+00
1708	648	PISADERA DE SUBARU FORESTER VARIOS	legacy	2026-07-24 14:19:44.077972+00
1709	648	PIS-VAR	legacy	2026-07-24 14:19:44.077972+00
1710	649	75831-20320	legacy	2026-07-24 14:19:44.077972+00
1711	649	Porta placa CELICA 90-93	legacy	2026-07-24 14:19:44.077972+00
1712	650	Porta placa CHARIOT GRANDIS	legacy	2026-07-24 14:19:44.077972+00
1713	650	MR-275638	legacy	2026-07-24 14:19:44.077972+00
1714	651	76801-35030	legacy	2026-07-24 14:19:44.077972+00
1715	651	Porta placa DE Maletera SURF	legacy	2026-07-24 14:19:44.077972+00
1716	652	Prensa Subaru DOMINGO	legacy	2026-07-24 14:19:44.077972+00
1717	652	FJC506	legacy	2026-07-24 14:19:44.077972+00
1718	653	PU-FORESTER-D	legacy	2026-07-24 14:19:44.077972+00
1719	653	Puerta SUBARU FORESTER ( Delantero Derecho )	legacy	2026-07-24 14:19:44.077972+00
1720	653	PU-FORESTER-D-R	legacy	2026-07-24 14:19:44.077972+00
1721	654	Puerta SUBARU FORESTER ( Trasero Isquierdo )	legacy	2026-07-24 14:19:44.077972+00
1722	654	PU-FORESTER-T-L	legacy	2026-07-24 14:19:44.077972+00
1723	654	PU-FORESTER-T	legacy	2026-07-24 14:19:44.077972+00
1724	655	Puerta SUBARU FORESTER ( Trasero Derecho )	legacy	2026-07-24 14:19:44.077972+00
1725	655	PU-FORESTER-T-R	legacy	2026-07-24 14:19:44.077972+00
1726	655	PU-FORESTER-T	legacy	2026-07-24 14:19:44.077972+00
1727	656	PU-EVO6-D	legacy	2026-07-24 14:19:44.077972+00
1728	656	PU-EVO6-D-L	legacy	2026-07-24 14:19:44.077972+00
1729	656	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Delantero Isquierdo )	legacy	2026-07-24 14:19:44.077972+00
1730	657	PU-EVO6-D	legacy	2026-07-24 14:19:44.077972+00
1731	657	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Delantero Derecho )	legacy	2026-07-24 14:19:44.077972+00
1732	657	PU-EVO6-D-R	legacy	2026-07-24 14:19:44.077972+00
1733	658	PU-EVO6-T	legacy	2026-07-24 14:19:44.077972+00
1734	658	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Trasero Isquierdo )	legacy	2026-07-24 14:19:44.077972+00
1735	658	PU-EVO6-T-L	legacy	2026-07-24 14:19:44.077972+00
1736	659	PU-EVO6-T-R	legacy	2026-07-24 14:19:44.077972+00
1737	659	Puerta MITSUBISHI LANCER EVOLUTION 6 ( Trasero Derecho )	legacy	2026-07-24 14:19:44.077972+00
1738	659	PU-EVO6-T	legacy	2026-07-24 14:19:44.077972+00
1739	660	PU-GVITARA-D	legacy	2026-07-24 14:19:44.077972+00
1740	660	PU-GVITARA-D-L	legacy	2026-07-24 14:19:44.077972+00
1741	660	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Delantero Isquierdo )	legacy	2026-07-24 14:19:44.077972+00
1742	661	PU-GVITARA-D	legacy	2026-07-24 14:19:44.077972+00
1743	661	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Delantero Derecho )	legacy	2026-07-24 14:19:44.077972+00
1744	661	PU-GVITARA-D-R	legacy	2026-07-24 14:19:44.077972+00
1745	662	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Trasero Isquierdo )	legacy	2026-07-24 14:19:44.077972+00
1746	662	PU-GVITARA-T	legacy	2026-07-24 14:19:44.077972+00
1747	662	PU-GVITARA-T-L	legacy	2026-07-24 14:19:44.077972+00
1748	663	Puerta SUZUKU GRAN VITARA 99 JUEGO DE ( Trasero Derecho )	legacy	2026-07-24 14:19:44.077972+00
1749	663	PU-GVITARA-T-R	legacy	2026-07-24 14:19:44.077972+00
1750	663	PU-GVITARA-T	legacy	2026-07-24 14:19:44.077972+00
1751	664	PU-IPSUM-D-L	legacy	2026-07-24 14:19:44.077972+00
1752	664	PU-IPSUM-D	legacy	2026-07-24 14:19:44.077972+00
1753	664	Puerta TOYOTA IPSUM ( Delantero Isquierdo )	legacy	2026-07-24 14:19:44.077972+00
1754	665	Amortiguador TRASERO CALDINA 4X4 TURING ®	legacy	2026-07-24 14:19:44.077972+00
1755	665	870005-G	legacy	2026-07-24 14:19:44.077972+00
1756	666	870006-G	legacy	2026-07-24 14:19:44.077972+00
1757	666	Amortiguador TRASERO CALDINA 4X4 TURING L{	legacy	2026-07-24 14:19:44.077972+00
1758	667	Radiador MITSUBISHI JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1759	667	RAD-JUNIOR	legacy	2026-07-24 14:19:44.077972+00
1760	668	Radiador NISSAN URVAN 01-06 E25	legacy	2026-07-24 14:19:44.077972+00
1761	668	21410-VW300	legacy	2026-07-24 14:19:44.077972+00
1762	669	RAD-CALDINAGT	legacy	2026-07-24 14:19:44.077972+00
1763	669	Radiador TOYOTA GT CALDINA	legacy	2026-07-24 14:19:44.077972+00
1764	670	333-1425	legacy	2026-07-24 14:19:44.077972+00
1765	670	333-1425-R	legacy	2026-07-24 14:19:44.077972+00
1766	670	Guiñador JEEP RENEGADE Mod. 2015~2016~2017~2018~2019~2020~ F/SML	legacy	2026-07-24 14:19:44.077972+00
1767	671	5646	legacy	2026-07-24 14:19:44.077972+00
1768	671	5646-L	legacy	2026-07-24 14:19:44.077972+00
1769	671	Espejo COROLLA AE 100 6 PINES	legacy	2026-07-24 14:19:44.077972+00
1770	672	5646-R	legacy	2026-07-24 14:19:44.077972+00
1771	672	5646	legacy	2026-07-24 14:19:44.077972+00
1772	672	Espejo COROLLA AE 100 6 PINES	legacy	2026-07-24 14:19:44.077972+00
1773	673	6207C3	legacy	2026-07-24 14:19:44.077972+00
1774	673	RODAMIENTO Motor F12	legacy	2026-07-24 14:19:44.077972+00
1775	674	RODAMIENTO SUBARU	legacy	2026-07-24 14:19:44.077972+00
1776	674	PJ18	legacy	2026-07-24 14:19:44.077972+00
1777	675	Stop BLUBIRT 96	legacy	2026-07-24 14:19:44.077972+00
1778	675	47-59-R	legacy	2026-07-24 14:19:44.077972+00
1779	675	47-59	legacy	2026-07-24 14:19:44.077972+00
1780	676	Stop CORONA 90	legacy	2026-07-24 14:19:44.077972+00
1781	676	20-199	legacy	2026-07-24 14:19:44.077972+00
1782	676	20-199-L	legacy	2026-07-24 14:19:44.077972+00
1783	677	20-199-R	legacy	2026-07-24 14:19:44.077972+00
1784	677	Stop CORONA 90	legacy	2026-07-24 14:19:44.077972+00
1785	677	20-199	legacy	2026-07-24 14:19:44.077972+00
1786	678	20-179-L	legacy	2026-07-24 14:19:44.077972+00
1787	678	20-179	legacy	2026-07-24 14:19:44.077972+00
1788	678	Stop CORONA 90 2 COLORES	legacy	2026-07-24 14:19:44.077972+00
1789	679	20-179-R	legacy	2026-07-24 14:19:44.077972+00
1790	679	20-179	legacy	2026-07-24 14:19:44.077972+00
1791	679	Stop CORONA 90 2 COLORES	legacy	2026-07-24 14:19:44.077972+00
1792	680	Stop CORONA 90 3 COLORES	legacy	2026-07-24 14:19:44.077972+00
1793	680	20-139-L	legacy	2026-07-24 14:19:44.077972+00
1794	680	20-139	legacy	2026-07-24 14:19:44.077972+00
1795	681	Stop CORONA 90 3 COLORES	legacy	2026-07-24 14:19:44.077972+00
1796	681	20-139-R	legacy	2026-07-24 14:19:44.077972+00
1797	681	20-139	legacy	2026-07-24 14:19:44.077972+00
1798	682	220-63436	legacy	2026-07-24 14:19:44.077972+00
1799	682	Stop NISSAN PHATFINDER	legacy	2026-07-24 14:19:44.077972+00
1800	682	220-63436-R	legacy	2026-07-24 14:19:44.077972+00
1801	683	SCOOTER	legacy	2026-07-24 14:19:44.077972+00
1802	684	SCOOTER CASCO	legacy	2026-07-24 14:19:44.077972+00
1803	684	SCOOTER-CA	legacy	2026-07-24 14:19:44.077972+00
1804	685	Espejo VARIOS ( Isquierdo )	legacy	2026-07-24 14:19:44.077972+00
1805	685	E-VAR-L	legacy	2026-07-24 14:19:44.077972+00
1806	685	E-VAR	legacy	2026-07-24 14:19:44.077972+00
1807	686	E-VAR-R	legacy	2026-07-24 14:19:44.077972+00
1808	686	E-VAR	legacy	2026-07-24 14:19:44.077972+00
1809	686	Espejo VARIOS ( Derecho )	legacy	2026-07-24 14:19:44.077972+00
1810	687	Stop AD 2006 215-194305	legacy	2026-07-24 14:19:44.077972+00
1811	687	220-24765-L	legacy	2026-07-24 14:19:44.077972+00
1812	687	220-24765	legacy	2026-07-24 14:19:44.077972+00
1813	688	4287	legacy	2026-07-24 14:19:44.077972+00
1814	688	4287-L	legacy	2026-07-24 14:19:44.077972+00
1815	688	Stop ATLAS 215-1915	legacy	2026-07-24 14:19:44.077972+00
1816	689	4287	legacy	2026-07-24 14:19:44.077972+00
1817	689	4287-R	legacy	2026-07-24 14:19:44.077972+00
1818	689	Stop ATLAS 215-1915	legacy	2026-07-24 14:19:44.077972+00
1819	690	220-51616	legacy	2026-07-24 14:19:44.077972+00
1820	690	Stop ATRAIL	legacy	2026-07-24 14:19:44.077972+00
1821	690	220-51616-L	legacy	2026-07-24 14:19:44.077972+00
1822	691	220-51616	legacy	2026-07-24 14:19:44.077972+00
1823	691	220-51616-R	legacy	2026-07-24 14:19:44.077972+00
1824	691	Stop ATRAIL	legacy	2026-07-24 14:19:44.077972+00
1825	692	4294-L	legacy	2026-07-24 14:19:44.077972+00
1826	692	4294	legacy	2026-07-24 14:19:44.077972+00
1827	692	Stop B11 CORTO	legacy	2026-07-24 14:19:44.077972+00
1828	693	1059	legacy	2026-07-24 14:19:44.077972+00
1829	693	1059-L	legacy	2026-07-24 14:19:44.077972+00
1830	693	Stop B14 NISSAN	legacy	2026-07-24 14:19:44.077972+00
1831	694	1059	legacy	2026-07-24 14:19:44.077972+00
1832	694	Stop B14 NISSAN	legacy	2026-07-24 14:19:44.077972+00
1833	694	1059-R	legacy	2026-07-24 14:19:44.077972+00
1834	695	Stop BONGO	legacy	2026-07-24 14:19:44.077972+00
1835	695	220-61871	legacy	2026-07-24 14:19:44.077972+00
1836	695	220-61871-R	legacy	2026-07-24 14:19:44.077972+00
1837	696	J21-L	legacy	2026-07-24 14:19:44.077972+00
1838	696	J21	legacy	2026-07-24 14:19:44.077972+00
1839	696	Stop BOXY	legacy	2026-07-24 14:19:44.077972+00
1840	697	J21	legacy	2026-07-24 14:19:44.077972+00
1841	697	J21-R	legacy	2026-07-24 14:19:44.077972+00
1842	697	Stop BOXY	legacy	2026-07-24 14:19:44.077972+00
1843	698	Stop CALDINA A MUELLE	legacy	2026-07-24 14:19:44.077972+00
1844	698	7352	legacy	2026-07-24 14:19:44.077972+00
1845	698	7352-R	legacy	2026-07-24 14:19:44.077972+00
1846	699	1231	legacy	2026-07-24 14:19:44.077972+00
1847	699	1231-L	legacy	2026-07-24 14:19:44.077972+00
1848	699	Stop CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
1849	700	1231-R	legacy	2026-07-24 14:19:44.077972+00
1850	700	1231	legacy	2026-07-24 14:19:44.077972+00
1851	700	Stop CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
1852	701	Stop CALDINA TURING	legacy	2026-07-24 14:19:44.077972+00
1853	701	7409-L	legacy	2026-07-24 14:19:44.077972+00
1854	701	7409	legacy	2026-07-24 14:19:44.077972+00
1855	702	Stop CALDINA TURING	legacy	2026-07-24 14:19:44.077972+00
1856	702	7409-R	legacy	2026-07-24 14:19:44.077972+00
1857	702	7409	legacy	2026-07-24 14:19:44.077972+00
1858	703	7157	legacy	2026-07-24 14:19:44.077972+00
1859	703	Stop CARIB 80	legacy	2026-07-24 14:19:44.077972+00
1860	703	7157-L	legacy	2026-07-24 14:19:44.077972+00
1861	704	Stop CARIB 90	legacy	2026-07-24 14:19:44.077972+00
1862	704	12-263-L	legacy	2026-07-24 14:19:44.077972+00
1863	704	12-263	legacy	2026-07-24 14:19:44.077972+00
1864	705	Stop CARIB 90	legacy	2026-07-24 14:19:44.077972+00
1865	705	12-263-R	legacy	2026-07-24 14:19:44.077972+00
1866	705	12-263	legacy	2026-07-24 14:19:44.077972+00
1867	706	13-55	legacy	2026-07-24 14:19:44.077972+00
1868	706	Stop CARIB BZ	legacy	2026-07-24 14:19:44.077972+00
1869	706	13-55-L	legacy	2026-07-24 14:19:44.077972+00
1870	707	13-55	legacy	2026-07-24 14:19:44.077972+00
1871	707	13-55-R	legacy	2026-07-24 14:19:44.077972+00
1872	707	Stop CARIB BZ	legacy	2026-07-24 14:19:44.077972+00
1873	708	Stop CARINA	legacy	2026-07-24 14:19:44.077972+00
1874	708	20-274-L	legacy	2026-07-24 14:19:44.077972+00
1875	708	20-274	legacy	2026-07-24 14:19:44.077972+00
1876	709	Stop CARINA	legacy	2026-07-24 14:19:44.077972+00
1877	709	20-274-R	legacy	2026-07-24 14:19:44.077972+00
1878	709	20-274	legacy	2026-07-24 14:19:44.077972+00
1879	710	Stop CARINA92	legacy	2026-07-24 14:19:44.077972+00
1880	710	53-07901-L	legacy	2026-07-24 14:19:44.077972+00
1881	710	53-07901	legacy	2026-07-24 14:19:44.077972+00
1882	711	53-07901-R	legacy	2026-07-24 14:19:44.077972+00
1883	711	Stop CARINA92	legacy	2026-07-24 14:19:44.077972+00
1884	711	53-07901	legacy	2026-07-24 14:19:44.077972+00
1885	712	33-09303-R	legacy	2026-07-24 14:19:44.077972+00
1886	712	Stop CELICA 90	legacy	2026-07-24 14:19:44.077972+00
1887	712	33-09303	legacy	2026-07-24 14:19:44.077972+00
1888	713	20-334-L	legacy	2026-07-24 14:19:44.077972+00
1889	713	Stop CELICA 99	legacy	2026-07-24 14:19:44.077972+00
1890	713	20-334	legacy	2026-07-24 14:19:44.077972+00
1891	714	Stop CELICA 99	legacy	2026-07-24 14:19:44.077972+00
1892	714	20-334	legacy	2026-07-24 14:19:44.077972+00
1893	714	20-334-R	legacy	2026-07-24 14:19:44.077972+00
1894	715	Stop CHANCHO CARAVAN	legacy	2026-07-24 14:19:44.077972+00
1895	715	4022	legacy	2026-07-24 14:19:44.077972+00
1896	715	4022-L	legacy	2026-07-24 14:19:44.077972+00
1897	716	Stop CHANCHO CARAVAN	legacy	2026-07-24 14:19:44.077972+00
1898	716	4022-R	legacy	2026-07-24 14:19:44.077972+00
1899	716	4022	legacy	2026-07-24 14:19:44.077972+00
1900	717	043-1566	legacy	2026-07-24 14:19:44.077972+00
1901	717	Stop COLT MITSUBISHI	legacy	2026-07-24 14:19:44.077972+00
1902	717	043-1566-L	legacy	2026-07-24 14:19:44.077972+00
1903	718	043-1566	legacy	2026-07-24 14:19:44.077972+00
1904	718	Stop COLT MITSUBISHI	legacy	2026-07-24 14:19:44.077972+00
1905	718	043-1566-R	legacy	2026-07-24 14:19:44.077972+00
1906	719	16-115	legacy	2026-07-24 14:19:44.077972+00
1907	719	16-115-L	legacy	2026-07-24 14:19:44.077972+00
1908	719	Stop COROLLA 2	legacy	2026-07-24 14:19:44.077972+00
1909	720	16-115-R	legacy	2026-07-24 14:19:44.077972+00
1910	720	16-115	legacy	2026-07-24 14:19:44.077972+00
1911	720	Stop COROLLA 2	legacy	2026-07-24 14:19:44.077972+00
1912	721	12-104-L	legacy	2026-07-24 14:19:44.077972+00
1913	721	Stop COROLLA 78	legacy	2026-07-24 14:19:44.077972+00
1914	721	12-104	legacy	2026-07-24 14:19:44.077972+00
1915	722	Stop COROLLA 83 212-1915	legacy	2026-07-24 14:19:44.077972+00
1916	722	12-173	legacy	2026-07-24 14:19:44.077972+00
1917	722	12-173-R	legacy	2026-07-24 14:19:44.077972+00
1918	723	13-29	legacy	2026-07-24 14:19:44.077972+00
1919	723	Stop COROLLA 89	legacy	2026-07-24 14:19:44.077972+00
1920	723	13-29-R	legacy	2026-07-24 14:19:44.077972+00
1921	724	12-327-R	legacy	2026-07-24 14:19:44.077972+00
1922	724	Stop COROLLA 90 212-1954	legacy	2026-07-24 14:19:44.077972+00
1923	724	12-327	legacy	2026-07-24 14:19:44.077972+00
1924	725	33-09307	legacy	2026-07-24 14:19:44.077972+00
1925	725	Stop COROLLA 92 212-1967	legacy	2026-07-24 14:19:44.077972+00
1926	725	33-09307-L	legacy	2026-07-24 14:19:44.077972+00
1927	726	33-09307-R	legacy	2026-07-24 14:19:44.077972+00
1928	726	33-09307	legacy	2026-07-24 14:19:44.077972+00
1929	726	Stop COROLLA 92 212-1967	legacy	2026-07-24 14:19:44.077972+00
1930	727	Stop COROLLA KE70	legacy	2026-07-24 14:19:44.077972+00
1931	727	12-127	legacy	2026-07-24 14:19:44.077972+00
1932	727	12-127-L	legacy	2026-07-24 14:19:44.077972+00
1933	728	Stop COROLLA KE70	legacy	2026-07-24 14:19:44.077972+00
1934	728	12-127	legacy	2026-07-24 14:19:44.077972+00
1935	728	12-127-R	legacy	2026-07-24 14:19:44.077972+00
1936	729	12-150-L	legacy	2026-07-24 14:19:44.077972+00
1937	729	Stop COROLLA KE75 212-1913	legacy	2026-07-24 14:19:44.077972+00
1938	729	12-150	legacy	2026-07-24 14:19:44.077972+00
1939	730	212-1967-R	legacy	2026-07-24 14:19:44.077972+00
1940	730	Stop COROLLA Mod. 92-94 Auto	legacy	2026-07-24 14:19:44.077972+00
1941	730	212-1967	legacy	2026-07-24 14:19:44.077972+00
1942	731	16-98	legacy	2026-07-24 14:19:44.077972+00
1943	731	Stop COROLLA2	legacy	2026-07-24 14:19:44.077972+00
1944	731	16-98-L	legacy	2026-07-24 14:19:44.077972+00
1945	732	16-98	legacy	2026-07-24 14:19:44.077972+00
1946	732	Stop COROLLA2	legacy	2026-07-24 14:19:44.077972+00
1947	732	16-98-R	legacy	2026-07-24 14:19:44.077972+00
1948	733	10-120-L	legacy	2026-07-24 14:19:44.077972+00
1949	733	10-120	legacy	2026-07-24 14:19:44.077972+00
1950	733	Stop CORONA 1 COLOR	legacy	2026-07-24 14:19:44.077972+00
1951	734	33-1105	legacy	2026-07-24 14:19:44.077972+00
1952	734	Stop CORONA 99 rojo y blanco	legacy	2026-07-24 14:19:44.077972+00
1953	734	33-1105-L	legacy	2026-07-24 14:19:44.077972+00
1954	735	33-1105	legacy	2026-07-24 14:19:44.077972+00
1955	735	Stop CORONA 99	legacy	2026-07-24 14:19:44.077972+00
1956	735	33-1105-R	legacy	2026-07-24 14:19:44.077972+00
1957	736	53-12003-L	legacy	2026-07-24 14:19:44.077972+00
1958	736	Stop CORSA	legacy	2026-07-24 14:19:44.077972+00
1959	736	53-12003	legacy	2026-07-24 14:19:44.077972+00
1960	737	53-12003-R	legacy	2026-07-24 14:19:44.077972+00
1961	737	Stop CORSA	legacy	2026-07-24 14:19:44.077972+00
1962	737	53-12003	legacy	2026-07-24 14:19:44.077972+00
1963	738	220-51328	legacy	2026-07-24 14:19:44.077972+00
1964	738	220-51328-R	legacy	2026-07-24 14:19:44.077972+00
1965	738	Stop DAIHATSU 95	legacy	2026-07-24 14:19:44.077972+00
1966	739	Stop DATSUN B310 1979	legacy	2026-07-24 14:19:44.077972+00
1967	739	4188	legacy	2026-07-24 14:19:44.077972+00
1968	739	4188-L	legacy	2026-07-24 14:19:44.077972+00
1969	740	Stop DATSUN B310 1979	legacy	2026-07-24 14:19:44.077972+00
1970	740	4188	legacy	2026-07-24 14:19:44.077972+00
1971	740	4188-R	legacy	2026-07-24 14:19:44.077972+00
1972	741	Stop DATSUN B310 1979	legacy	2026-07-24 14:19:44.077972+00
1973	741	7110	legacy	2026-07-24 14:19:44.077972+00
1974	741	7110-L	legacy	2026-07-24 14:19:44.077972+00
1975	742	Stop DATSUN B310 1979	legacy	2026-07-24 14:19:44.077972+00
1976	742	7110-R	legacy	2026-07-24 14:19:44.077972+00
1977	742	7110	legacy	2026-07-24 14:19:44.077972+00
1978	743	Stop DE LEGACY	legacy	2026-07-24 14:19:44.077972+00
1979	743	1053	legacy	2026-07-24 14:19:44.077972+00
1980	743	1053-L	legacy	2026-07-24 14:19:44.077972+00
1981	744	Stop DE LEGACY	legacy	2026-07-24 14:19:44.077972+00
1982	744	1053	legacy	2026-07-24 14:19:44.077972+00
1983	744	1053-R	legacy	2026-07-24 14:19:44.077972+00
1984	745	334-1906-L	legacy	2026-07-24 14:19:44.077972+00
1985	745	334-1906	legacy	2026-07-24 14:19:44.077972+00
1986	745	Stop DODGE RAM 1500 2500 PICK UP Mod.2002~2003~2004~2005~2006	legacy	2026-07-24 14:19:44.077972+00
1987	746	334-1906	legacy	2026-07-24 14:19:44.077972+00
1988	746	334-1906-R	legacy	2026-07-24 14:19:44.077972+00
1989	746	Stop DODGE RAM 1500 2500 PICK UP Mod.2002~2003~2004~2005~2006	legacy	2026-07-24 14:19:44.077972+00
1990	747	231-1955-L	legacy	2026-07-24 14:19:44.077972+00
1991	747	231-1955	legacy	2026-07-24 14:19:44.077972+00
1992	747	Stop Ford RANGER Mod. 2008~2009~2010~2011	legacy	2026-07-24 14:19:44.077972+00
1993	748	Stop FORESTER2000	legacy	2026-07-24 14:19:44.077972+00
1994	748	220-20697	legacy	2026-07-24 14:19:44.077972+00
1995	748	220-20697-L	legacy	2026-07-24 14:19:44.077972+00
1996	749	Stop FORESTER2000	legacy	2026-07-24 14:19:44.077972+00
1997	749	220-20697-R	legacy	2026-07-24 14:19:44.077972+00
1998	749	220-20697	legacy	2026-07-24 14:19:44.077972+00
1999	750	Stop FX	legacy	2026-07-24 14:19:44.077972+00
2000	750	795-R	legacy	2026-07-24 14:19:44.077972+00
2001	750	795	legacy	2026-07-24 14:19:44.077972+00
2002	751	Stop GRAND VIA 212-19B3	legacy	2026-07-24 14:19:44.077972+00
2003	751	26-55-L	legacy	2026-07-24 14:19:44.077972+00
2004	751	26-55	legacy	2026-07-24 14:19:44.077972+00
2005	752	Stop GRAND VIA 212-19B3	legacy	2026-07-24 14:19:44.077972+00
2006	752	26-55	legacy	2026-07-24 14:19:44.077972+00
2007	752	26-55-R	legacy	2026-07-24 14:19:44.077972+00
2008	753	26-15	legacy	2026-07-24 14:19:44.077972+00
2009	753	26-15-L	legacy	2026-07-24 14:19:44.077972+00
2010	753	Stop HIACE CUADRADO	legacy	2026-07-24 14:19:44.077972+00
2011	754	212-1916	legacy	2026-07-24 14:19:44.077972+00
2012	754	Stop HIACE Mod 84/87	legacy	2026-07-24 14:19:44.077972+00
2013	754	212-1916-R	legacy	2026-07-24 14:19:44.077972+00
2014	755	33-07803-L	legacy	2026-07-24 14:19:44.077972+00
2015	755	33-07803	legacy	2026-07-24 14:19:44.077972+00
2016	755	Stop HILUX SUF 96	legacy	2026-07-24 14:19:44.077972+00
2017	756	33-07803-R	legacy	2026-07-24 14:19:44.077972+00
2018	756	33-07803	legacy	2026-07-24 14:19:44.077972+00
2019	756	Stop HILUX SUF 96	legacy	2026-07-24 14:19:44.077972+00
2020	757	1167	legacy	2026-07-24 14:19:44.077972+00
2021	757	Stop HONDA CRV	legacy	2026-07-24 14:19:44.077972+00
2022	757	1167-L	legacy	2026-07-24 14:19:44.077972+00
2023	758	1167-R	legacy	2026-07-24 14:19:44.077972+00
2024	758	1167	legacy	2026-07-24 14:19:44.077972+00
2025	758	Stop HONDA CRV	legacy	2026-07-24 14:19:44.077972+00
2026	759	MB952979-L	legacy	2026-07-24 14:19:44.077972+00
2027	759	STOP MITSUBISHI CARISMA 97-99	legacy	2026-07-24 14:19:44.077972+00
2028	759	MB952979	legacy	2026-07-24 14:19:44.077972+00
2029	760	STOP MITSUBISHI CARISMA 97-99	legacy	2026-07-24 14:19:44.077972+00
2030	760	MB952979-R	legacy	2026-07-24 14:19:44.077972+00
2031	760	MB952979	legacy	2026-07-24 14:19:44.077972+00
2032	761	01405	legacy	2026-07-24 14:19:44.077972+00
2033	761	Stop HONDA EG	legacy	2026-07-24 14:19:44.077972+00
2034	761	01405-L	legacy	2026-07-24 14:19:44.077972+00
2035	762	01405-R	legacy	2026-07-24 14:19:44.077972+00
2036	762	Stop HONDA EG	legacy	2026-07-24 14:19:44.077972+00
2037	762	01405	legacy	2026-07-24 14:19:44.077972+00
2038	763	Stop HONDA EK	legacy	2026-07-24 14:19:44.077972+00
2039	763	043-1262-L	legacy	2026-07-24 14:19:44.077972+00
2040	763	043-1262	legacy	2026-07-24 14:19:44.077972+00
2041	764	043-1262-R	legacy	2026-07-24 14:19:44.077972+00
2042	764	Stop HONDA EK	legacy	2026-07-24 14:19:44.077972+00
2043	764	043-1262	legacy	2026-07-24 14:19:44.077972+00
2044	765	Stop HONDA VARIOS	legacy	2026-07-24 14:19:44.077972+00
2045	765	043-1212	legacy	2026-07-24 14:19:44.077972+00
2046	765	043-1212-L	legacy	2026-07-24 14:19:44.077972+00
2047	766	Stop HONDA VARIOS	legacy	2026-07-24 14:19:44.077972+00
2048	766	043-1212	legacy	2026-07-24 14:19:44.077972+00
2049	766	043-1212-R	legacy	2026-07-24 14:19:44.077972+00
2050	767	Stop IMPREZA	legacy	2026-07-24 14:19:44.077972+00
2051	767	220-20553-L	legacy	2026-07-24 14:19:44.077972+00
2052	767	220-20553	legacy	2026-07-24 14:19:44.077972+00
2053	768	Stop IMPREZA	legacy	2026-07-24 14:19:44.077972+00
2054	768	220-20553-R	legacy	2026-07-24 14:19:44.077972+00
2055	768	220-20553	legacy	2026-07-24 14:19:44.077972+00
2056	769	220-22185-R	legacy	2026-07-24 14:19:44.077972+00
2057	769	220-22185	legacy	2026-07-24 14:19:44.077972+00
2058	769	Stop INTEGRA HONDA	legacy	2026-07-24 14:19:44.077972+00
2059	770	Stop INTEGRA HONDA	legacy	2026-07-24 14:19:44.077972+00
2060	770	220-22220-L	legacy	2026-07-24 14:19:44.077972+00
2061	770	220-22220	legacy	2026-07-24 14:19:44.077972+00
2062	771	1311-L	legacy	2026-07-24 14:19:44.077972+00
2063	771	Stop IO	legacy	2026-07-24 14:19:44.077972+00
2064	771	1311	legacy	2026-07-24 14:19:44.077972+00
2065	772	Stop IO	legacy	2026-07-24 14:19:44.077972+00
2066	772	1311-R	legacy	2026-07-24 14:19:44.077972+00
2067	772	1311	legacy	2026-07-24 14:19:44.077972+00
2068	773	Stop IPSUM	legacy	2026-07-24 14:19:44.077972+00
2069	773	44-5	legacy	2026-07-24 14:19:44.077972+00
2070	773	44-5-R	legacy	2026-07-24 14:19:44.077972+00
2071	774	212-1904	legacy	2026-07-24 14:19:44.077972+00
2072	774	Stop LAND CRUISSER DINA Mod.74~81 UNIVERSAL	legacy	2026-07-24 14:19:44.077972+00
2073	774	212-1904-L	legacy	2026-07-24 14:19:44.077972+00
2074	775	212-1904	legacy	2026-07-24 14:19:44.077972+00
2075	775	Stop LAND CRUISSER DINA Mod.74~81 UNIVERSAL	legacy	2026-07-24 14:19:44.077972+00
2076	775	212-1904-R	legacy	2026-07-24 14:19:44.077972+00
2077	776	Stop LEVIN AE 92	legacy	2026-07-24 14:19:44.077972+00
2078	776	12-426-L	legacy	2026-07-24 14:19:44.077972+00
2079	776	12-426	legacy	2026-07-24 14:19:44.077972+00
2080	777	Stop LEVIN TOYOTA LEVIN 90	legacy	2026-07-24 14:19:44.077972+00
2081	777	7337	legacy	2026-07-24 14:19:44.077972+00
2082	777	7337-L	legacy	2026-07-24 14:19:44.077972+00
2083	778	Stop LEVIN TOYOTA LEVIN 90	legacy	2026-07-24 14:19:44.077972+00
2084	778	7337	legacy	2026-07-24 14:19:44.077972+00
2085	778	7337-R	legacy	2026-07-24 14:19:44.077972+00
2086	779	7370	legacy	2026-07-24 14:19:44.077972+00
2087	779	7370-L	legacy	2026-07-24 14:19:44.077972+00
2088	779	Stop LEVN 92	legacy	2026-07-24 14:19:44.077972+00
2089	780	7370-R	legacy	2026-07-24 14:19:44.077972+00
2090	780	7370	legacy	2026-07-24 14:19:44.077972+00
2091	780	Stop LEVN 92	legacy	2026-07-24 14:19:44.077972+00
2092	781	28-97-L	legacy	2026-07-24 14:19:44.077972+00
2093	781	28-97	legacy	2026-07-24 14:19:44.077972+00
2094	781	Stop LITE ACE 212-1983	legacy	2026-07-24 14:19:44.077972+00
2095	782	28-97-R	legacy	2026-07-24 14:19:44.077972+00
2096	782	28-97	legacy	2026-07-24 14:19:44.077972+00
2097	782	Stop LITE ACE 212-1983	legacy	2026-07-24 14:19:44.077972+00
2098	783	4886-L	legacy	2026-07-24 14:19:44.077972+00
2099	783	4886	legacy	2026-07-24 14:19:44.077972+00
2100	783	Stop MARCH	legacy	2026-07-24 14:19:44.077972+00
2101	784	4886-R	legacy	2026-07-24 14:19:44.077972+00
2102	784	4886	legacy	2026-07-24 14:19:44.077972+00
2103	784	Stop MARCH	legacy	2026-07-24 14:19:44.077972+00
2104	785	216-1992-L	legacy	2026-07-24 14:19:44.077972+00
2105	785	216-1992	legacy	2026-07-24 14:19:44.077972+00
2106	785	Stop Mazda BT-50 Mod.2012~2014 Pick Up Camioneta	legacy	2026-07-24 14:19:44.077972+00
2107	786	216-1992-R	legacy	2026-07-24 14:19:44.077972+00
2108	786	216-1992	legacy	2026-07-24 14:19:44.077972+00
2109	786	Stop Mazda BT-50 Mod.2012~2014 Pick Up Camioneta	legacy	2026-07-24 14:19:44.077972+00
2110	787	Stop MAZDA BT-50 Mod.2015~2016~2017~2018~2019~2020	legacy	2026-07-24 14:19:44.077972+00
2111	787	216-19AG-L	legacy	2026-07-24 14:19:44.077972+00
2112	787	216-19AG	legacy	2026-07-24 14:19:44.077972+00
2113	788	Stop MAZDA BT-50 Mod.2015~2016~2017~2018~2019~2020	legacy	2026-07-24 14:19:44.077972+00
2114	788	216-19AG	legacy	2026-07-24 14:19:44.077972+00
2115	788	216-19AG-R	legacy	2026-07-24 14:19:44.077972+00
2116	789	Stop MITSUBISHI CHARIOT GRANDIS	legacy	2026-07-24 14:19:44.077972+00
2117	789	31-11301	legacy	2026-07-24 14:19:44.077972+00
2118	789	31-11301-L	legacy	2026-07-24 14:19:44.077972+00
2119	790	31-11301-R	legacy	2026-07-24 14:19:44.077972+00
2120	790	Stop MITSUBISHI CHARIOT GRANDIS	legacy	2026-07-24 14:19:44.077972+00
2121	790	31-11301	legacy	2026-07-24 14:19:44.077972+00
2122	791	043-8557	legacy	2026-07-24 14:19:44.077972+00
2123	791	043-8557-L	legacy	2026-07-24 14:19:44.077972+00
2124	791	Stop MITSUBISHI COULT 3 1989	legacy	2026-07-24 14:19:44.077972+00
2125	792	043-8557	legacy	2026-07-24 14:19:44.077972+00
2126	792	Stop MITSUBISHI COULT 3 1989	legacy	2026-07-24 14:19:44.077972+00
2127	792	043-8557-R	legacy	2026-07-24 14:19:44.077972+00
2128	793	043-1593-L	legacy	2026-07-24 14:19:44.077972+00
2129	793	043-1593	legacy	2026-07-24 14:19:44.077972+00
2130	793	Stop MITSUBISHI GALANT	legacy	2026-07-24 14:19:44.077972+00
2131	794	Stop MITSUBISHI JUNIOR	legacy	2026-07-24 14:19:44.077972+00
2132	794	1121-R	legacy	2026-07-24 14:19:44.077972+00
2133	794	1121	legacy	2026-07-24 14:19:44.077972+00
2134	795	214-1941	legacy	2026-07-24 14:19:44.077972+00
2135	795	214-1941-L	legacy	2026-07-24 14:19:44.077972+00
2136	795	Stop Mitsubishi LANCER Mod. 92~93~94~95~96 LIBERO	legacy	2026-07-24 14:19:44.077972+00
2137	796	Stop MITSUBSHI DELICA	legacy	2026-07-24 14:19:44.077972+00
2138	796	220-37508-L	legacy	2026-07-24 14:19:44.077972+00
2139	796	220-37508	legacy	2026-07-24 14:19:44.077972+00
2140	797	Stop MITSUBSHI DELICA	legacy	2026-07-24 14:19:44.077972+00
2141	797	220-37508-R	legacy	2026-07-24 14:19:44.077972+00
2142	797	220-37508	legacy	2026-07-24 14:19:44.077972+00
2143	798	043-6772	legacy	2026-07-24 14:19:44.077972+00
2144	798	043-6772-L	legacy	2026-07-24 14:19:44.077972+00
2145	798	Stop MONTERO 214-1922	legacy	2026-07-24 14:19:44.077972+00
2146	799	043-6772	legacy	2026-07-24 14:19:44.077972+00
2147	799	043-6772-R	legacy	2026-07-24 14:19:44.077972+00
2148	799	Stop MONTERO 214-1922	legacy	2026-07-24 14:19:44.077972+00
2149	800	220-24522-L	legacy	2026-07-24 14:19:44.077972+00
2150	800	Stop NA 20 URVAN 215-1942	legacy	2026-07-24 14:19:44.077972+00
2151	800	220-24522	legacy	2026-07-24 14:19:44.077972+00
2152	801	Stop NA 20 URVAN 215-1942	legacy	2026-07-24 14:19:44.077972+00
2153	801	220-24522	legacy	2026-07-24 14:19:44.077972+00
2154	801	220-24522-R	legacy	2026-07-24 14:19:44.077972+00
2155	802	7309	legacy	2026-07-24 14:19:44.077972+00
2156	802	7309-R	legacy	2026-07-24 14:19:44.077972+00
2157	802	Stop NISSAN AD WAGON	legacy	2026-07-24 14:19:44.077972+00
2158	803	220-24555-L	legacy	2026-07-24 14:19:44.077972+00
2159	803	220-24555	legacy	2026-07-24 14:19:44.077972+00
2160	803	Stop NISSAN AD Y10	legacy	2026-07-24 14:19:44.077972+00
2161	804	220-24555	legacy	2026-07-24 14:19:44.077972+00
2162	804	220-24555-R	legacy	2026-07-24 14:19:44.077972+00
2163	804	Stop NISSAN AD Y10	legacy	2026-07-24 14:19:44.077972+00
2164	805	4339	legacy	2026-07-24 14:19:44.077972+00
2165	805	Stop NISSAN B11 LARGO	legacy	2026-07-24 14:19:44.077972+00
2166	805	4339-R	legacy	2026-07-24 14:19:44.077972+00
2167	806	33-10505-L	legacy	2026-07-24 14:19:44.077972+00
2168	806	33-10505	legacy	2026-07-24 14:19:44.077972+00
2169	806	Stop NISSAN CUSTOM E 24	legacy	2026-07-24 14:19:44.077972+00
2170	807	33-10505	legacy	2026-07-24 14:19:44.077972+00
2171	807	Stop NISSAN CUSTOM E 24	legacy	2026-07-24 14:19:44.077972+00
2172	807	33-10505-R	legacy	2026-07-24 14:19:44.077972+00
2173	808	Stop NISSAN MARCH 97 a rayas	legacy	2026-07-24 14:19:44.077972+00
2174	808	7327-L	legacy	2026-07-24 14:19:44.077972+00
2175	808	7327	legacy	2026-07-24 14:19:44.077972+00
2176	809	Stop NISSAN MARCH 97 a rayas	legacy	2026-07-24 14:19:44.077972+00
2177	809	7327-R	legacy	2026-07-24 14:19:44.077972+00
2178	809	7327	legacy	2026-07-24 14:19:44.077972+00
2179	810	Stop NISSAN PULSAR	legacy	2026-07-24 14:19:44.077972+00
2180	810	7379-L	legacy	2026-07-24 14:19:44.077972+00
2181	810	7379	legacy	2026-07-24 14:19:44.077972+00
2182	811	Stop NISSAN PULSAR	legacy	2026-07-24 14:19:44.077972+00
2183	811	7379	legacy	2026-07-24 14:19:44.077972+00
2184	811	7379-R	legacy	2026-07-24 14:19:44.077972+00
2185	812	220-52458-L	legacy	2026-07-24 14:19:44.077972+00
2186	812	Stop NISSAN SERENA	legacy	2026-07-24 14:19:44.077972+00
2187	812	220-52458	legacy	2026-07-24 14:19:44.077972+00
2188	813	220-52458	legacy	2026-07-24 14:19:44.077972+00
2189	813	Stop NISSAN SERENA	legacy	2026-07-24 14:19:44.077972+00
2190	813	220-52458-R	legacy	2026-07-24 14:19:44.077972+00
2371	874	52-049	legacy	2026-07-24 14:19:44.077972+00
2191	814	Stop NISSAN SUNNY B12	legacy	2026-07-24 14:19:44.077972+00
2192	814	4363-L	legacy	2026-07-24 14:19:44.077972+00
2193	814	4363	legacy	2026-07-24 14:19:44.077972+00
2194	815	4363-R	legacy	2026-07-24 14:19:44.077972+00
2195	815	Stop NISSAN SUNNY B12	legacy	2026-07-24 14:19:44.077972+00
2196	815	4363	legacy	2026-07-24 14:19:44.077972+00
2197	816	Stop NISSAN SUNNY B13 DOBLE LINEA 215-1991	legacy	2026-07-24 14:19:44.077972+00
2198	816	7344-L	legacy	2026-07-24 14:19:44.077972+00
2199	816	7344	legacy	2026-07-24 14:19:44.077972+00
2200	817	Stop NISSAN SUNNY B13 DOBLE LINEA 215-1991	legacy	2026-07-24 14:19:44.077972+00
2201	817	7344-R	legacy	2026-07-24 14:19:44.077972+00
2202	817	7344	legacy	2026-07-24 14:19:44.077972+00
2203	818	Stop Nissan URVAN Mod.90~ E24 Minibus E2	legacy	2026-07-24 14:19:44.077972+00
2204	818	215-1942	legacy	2026-07-24 14:19:44.077972+00
2205	818	215-1942-R	legacy	2026-07-24 14:19:44.077972+00
2206	819	043-1150	legacy	2026-07-24 14:19:44.077972+00
2207	819	043-1150-L	legacy	2026-07-24 14:19:44.077972+00
2208	819	Stop PRELUDE	legacy	2026-07-24 14:19:44.077972+00
2209	820	043-1150	legacy	2026-07-24 14:19:44.077972+00
2210	820	Stop PRELUDE	legacy	2026-07-24 14:19:44.077972+00
2211	820	043-1150-R	legacy	2026-07-24 14:19:44.077972+00
2212	821	7307-L	legacy	2026-07-24 14:19:44.077972+00
2213	821	Stop PRESSEA	legacy	2026-07-24 14:19:44.077972+00
2214	821	7307	legacy	2026-07-24 14:19:44.077972+00
2215	822	7307-R	legacy	2026-07-24 14:19:44.077972+00
2216	822	Stop PRESSEA	legacy	2026-07-24 14:19:44.077972+00
2217	822	7307	legacy	2026-07-24 14:19:44.077972+00
2218	823	10-85-R	legacy	2026-07-24 14:19:44.077972+00
2219	823	10-85	legacy	2026-07-24 14:19:44.077972+00
2220	823	Stop REFLEX	legacy	2026-07-24 14:19:44.077972+00
2221	824	Stop Renault SANDERO STEPWAY Mod. 2012~2013~2014~2015	legacy	2026-07-24 14:19:44.077972+00
2222	824	551-19A2	legacy	2026-07-24 14:19:44.077972+00
2223	824	551-19A2-R	legacy	2026-07-24 14:19:44.077972+00
2224	825	043-1536-L	legacy	2026-07-24 14:19:44.077972+00
2225	825	Stop RVR 92	legacy	2026-07-24 14:19:44.077972+00
2226	825	043-1536	legacy	2026-07-24 14:19:44.077972+00
2227	826	043-1536-R	legacy	2026-07-24 14:19:44.077972+00
2228	826	Stop RVR 92	legacy	2026-07-24 14:19:44.077972+00
2229	826	043-1536	legacy	2026-07-24 14:19:44.077972+00
2230	827	043-1550	legacy	2026-07-24 14:19:44.077972+00
2231	827	Stop RVR BI COLOR	legacy	2026-07-24 14:19:44.077972+00
2232	827	043-1550-L	legacy	2026-07-24 14:19:44.077972+00
2233	828	043-1550	legacy	2026-07-24 14:19:44.077972+00
2234	828	Stop RVR BI COLOR	legacy	2026-07-24 14:19:44.077972+00
2235	828	043-1550-R	legacy	2026-07-24 14:19:44.077972+00
2236	829	Stop SOLEI EP82	legacy	2026-07-24 14:19:44.077972+00
2237	829	33-1300	legacy	2026-07-24 14:19:44.077972+00
2238	829	33-1300-R	legacy	2026-07-24 14:19:44.077972+00
2239	830	33-1300-L	legacy	2026-07-24 14:19:44.077972+00
2240	830	Stop SOLEI EP82	legacy	2026-07-24 14:19:44.077972+00
2241	830	33-1300	legacy	2026-07-24 14:19:44.077972+00
2242	831	Stop SPRINTER 93	legacy	2026-07-24 14:19:44.077972+00
2243	831	12-353	legacy	2026-07-24 14:19:44.077972+00
2244	831	12-353-R	legacy	2026-07-24 14:19:44.077972+00
2245	832	1079	legacy	2026-07-24 14:19:44.077972+00
2246	832	1079-L	legacy	2026-07-24 14:19:44.077972+00
2247	832	Stop STARLET	legacy	2026-07-24 14:19:44.077972+00
2248	833	1079	legacy	2026-07-24 14:19:44.077972+00
2249	833	1079-R	legacy	2026-07-24 14:19:44.077972+00
2250	833	Stop STARLET	legacy	2026-07-24 14:19:44.077972+00
2251	834	Stop STARLET EP82	legacy	2026-07-24 14:19:44.077972+00
2252	834	53-07601	legacy	2026-07-24 14:19:44.077972+00
2253	834	53-07601-L	legacy	2026-07-24 14:19:44.077972+00
2254	835	Stop STARLET EP82	legacy	2026-07-24 14:19:44.077972+00
2255	835	53-07601-R	legacy	2026-07-24 14:19:44.077972+00
2256	835	53-07601	legacy	2026-07-24 14:19:44.077972+00
2257	836	220-75539-R	legacy	2026-07-24 14:19:44.077972+00
2258	836	Stop STARLET EP82 TURBO	legacy	2026-07-24 14:19:44.077972+00
2259	836	220-75539	legacy	2026-07-24 14:19:44.077972+00
2260	837	4340-L	legacy	2026-07-24 14:19:44.077972+00
2261	837	4340	legacy	2026-07-24 14:19:44.077972+00
2262	837	Stop SUABU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
2263	838	4340	legacy	2026-07-24 14:19:44.077972+00
2264	838	Stop SUABU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
2265	838	4340-R	legacy	2026-07-24 14:19:44.077972+00
2266	839	Stop SUBARU 97	legacy	2026-07-24 14:19:44.077972+00
2267	839	220-20597-L	legacy	2026-07-24 14:19:44.077972+00
2268	839	220-20597	legacy	2026-07-24 14:19:44.077972+00
2269	840	Stop SUBARU 97	legacy	2026-07-24 14:19:44.077972+00
2270	840	220-20597-R	legacy	2026-07-24 14:19:44.077972+00
2271	840	220-20597	legacy	2026-07-24 14:19:44.077972+00
2272	841	Stop SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
2273	841	2074	legacy	2026-07-24 14:19:44.077972+00
2274	841	2074-L	legacy	2026-07-24 14:19:44.077972+00
2275	842	Stop SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
2276	842	2074	legacy	2026-07-24 14:19:44.077972+00
2277	842	2074-R	legacy	2026-07-24 14:19:44.077972+00
2278	843	Stop SUBARU LEGACY 92 VERIFICAR MOD	legacy	2026-07-24 14:19:44.077972+00
2279	843	220-20491-R	legacy	2026-07-24 14:19:44.077972+00
2280	843	220-20491	legacy	2026-07-24 14:19:44.077972+00
2281	844	836-L	legacy	2026-07-24 14:19:44.077972+00
2282	844	Stop SUNNY B13 215-1967	legacy	2026-07-24 14:19:44.077972+00
2284	845	Stop SUNNY B13 215-1967	legacy	2026-07-24 14:19:44.077972+00
2285	845	836	legacy	2026-07-24 14:19:44.077972+00
2286	845	836-R	legacy	2026-07-24 14:19:44.077972+00
2287	846	218-1905	legacy	2026-07-24 14:19:44.077972+00
2288	846	218-1905-R	legacy	2026-07-24 14:19:44.077972+00
2289	846	Stop Suzuki SAMURAI	legacy	2026-07-24 14:19:44.077972+00
2290	847	Stop Suzuqui ERTIGA Mod. 2011 2012~2013~2014	legacy	2026-07-24 14:19:44.077972+00
2291	847	218-1974	legacy	2026-07-24 14:19:44.077972+00
2292	847	218-1974-R	legacy	2026-07-24 14:19:44.077972+00
2293	848	218-1949-L	legacy	2026-07-24 14:19:44.077972+00
2294	848	218-1949	legacy	2026-07-24 14:19:44.077972+00
2295	848	Stop Suzuqui GRAN VITARA Mod.2005 Cristal 2	legacy	2026-07-24 14:19:44.077972+00
2296	849	218-1949-R	legacy	2026-07-24 14:19:44.077972+00
2297	849	218-1949	legacy	2026-07-24 14:19:44.077972+00
2298	849	Stop Suzuqui GRAN VITARA Mod.2005 Cristal 2	legacy	2026-07-24 14:19:44.077972+00
2299	850	312-19C2-L	legacy	2026-07-24 14:19:44.077972+00
2300	850	Stop Toyota 4RUNNER Mod. 2013~2014~2015~2016~2017. LED	legacy	2026-07-24 14:19:44.077972+00
2301	850	312-19C2	legacy	2026-07-24 14:19:44.077972+00
2302	851	312-19C2-R	legacy	2026-07-24 14:19:44.077972+00
2303	851	Stop Toyota 4RUNNER Mod. 2013~2014~2015~2016~2017. LED	legacy	2026-07-24 14:19:44.077972+00
2304	851	312-19C2	legacy	2026-07-24 14:19:44.077972+00
2305	852	20-222	legacy	2026-07-24 14:19:44.077972+00
2306	852	20-222-L	legacy	2026-07-24 14:19:44.077972+00
2307	852	Stop TOYOTA CARINA 91	legacy	2026-07-24 14:19:44.077972+00
2308	853	20-222	legacy	2026-07-24 14:19:44.077972+00
2309	853	20-222-R	legacy	2026-07-24 14:19:44.077972+00
2310	853	Stop TOYOTA CARINA 91	legacy	2026-07-24 14:19:44.077972+00
2311	854	12-259-R	legacy	2026-07-24 14:19:44.077972+00
2312	854	Stop TOYOTA COROLLA 212-1935-1	legacy	2026-07-24 14:19:44.077972+00
2313	854	12-259	legacy	2026-07-24 14:19:44.077972+00
2314	855	20-161-R	legacy	2026-07-24 14:19:44.077972+00
2315	855	20-161	legacy	2026-07-24 14:19:44.077972+00
2316	855	Stop TOYOTA CORONA con retro	legacy	2026-07-24 14:19:44.077972+00
2317	856	33-09803-L	legacy	2026-07-24 14:19:44.077972+00
2318	856	Stop TOYOTA LEVIN	legacy	2026-07-24 14:19:44.077972+00
2319	856	33-09803	legacy	2026-07-24 14:19:44.077972+00
2320	857	33-09803-R	legacy	2026-07-24 14:19:44.077972+00
2321	857	Stop TOYOTA LEVIN	legacy	2026-07-24 14:19:44.077972+00
2322	857	33-09803	legacy	2026-07-24 14:19:44.077972+00
2323	858	33-13003-R	legacy	2026-07-24 14:19:44.077972+00
2324	858	Stop TOYOTA SINOS VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
2325	858	33-13003	legacy	2026-07-24 14:19:44.077972+00
2326	859	212-19Y002-U	legacy	2026-07-24 14:19:44.077972+00
2327	859	212-19Y002-U-L	legacy	2026-07-24 14:19:44.077972+00
2328	859	Stop TOYOTA SUCCED 212-19Y002	legacy	2026-07-24 14:19:44.077972+00
2329	860	212-19Y002-U	legacy	2026-07-24 14:19:44.077972+00
2330	860	212-19Y002-U-R	legacy	2026-07-24 14:19:44.077972+00
2331	860	Stop TOYOTA SUCCED 212-19Y002	legacy	2026-07-24 14:19:44.077972+00
2332	861	33-12103	legacy	2026-07-24 14:19:44.077972+00
2333	861	33-12103-L	legacy	2026-07-24 14:19:44.077972+00
2334	861	Stop TOYOTA TERCEL	legacy	2026-07-24 14:19:44.077972+00
2335	862	33-12103	legacy	2026-07-24 14:19:44.077972+00
2336	862	Stop TOYOTA TERCEL	legacy	2026-07-24 14:19:44.077972+00
2337	862	33-12103-R	legacy	2026-07-24 14:19:44.077972+00
2338	863	32-128-L	legacy	2026-07-24 14:19:44.077972+00
2339	863	Stop TOYOTA WINDOWN	legacy	2026-07-24 14:19:44.077972+00
2340	863	32-128	legacy	2026-07-24 14:19:44.077972+00
2341	864	32-128-R	legacy	2026-07-24 14:19:44.077972+00
2342	864	Stop TOYOTA WINDOWN	legacy	2026-07-24 14:19:44.077972+00
2343	864	32-128	legacy	2026-07-24 14:19:44.077972+00
2344	865	12-319-R	legacy	2026-07-24 14:19:44.077972+00
2345	865	Stop TRUENO 90	legacy	2026-07-24 14:19:44.077972+00
2346	865	12-319	legacy	2026-07-24 14:19:44.077972+00
2347	866	Stop TRUENO 90 AE92	legacy	2026-07-24 14:19:44.077972+00
2348	866	12-301-R	legacy	2026-07-24 14:19:44.077972+00
2349	866	12-301	legacy	2026-07-24 14:19:44.077972+00
2350	867	Stop TRUENO 96	legacy	2026-07-24 14:19:44.077972+00
2351	867	220-76610-L	legacy	2026-07-24 14:19:44.077972+00
2352	867	220-76610	legacy	2026-07-24 14:19:44.077972+00
2353	868	Stop TRUENO 96	legacy	2026-07-24 14:19:44.077972+00
2354	868	220-76610-R	legacy	2026-07-24 14:19:44.077972+00
2355	868	220-76610	legacy	2026-07-24 14:19:44.077972+00
2356	869	Stop VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
2357	869	7324-L	legacy	2026-07-24 14:19:44.077972+00
2358	869	7324	legacy	2026-07-24 14:19:44.077972+00
2359	870	Stop VIATARA ESCUDO	legacy	2026-07-24 14:19:44.077972+00
2360	870	220-32224-R	legacy	2026-07-24 14:19:44.077972+00
2361	870	220-32224	legacy	2026-07-24 14:19:44.077972+00
2362	871	Stop VITARA ESCUDO	legacy	2026-07-24 14:19:44.077972+00
2363	871	220-32224-L	legacy	2026-07-24 14:19:44.077972+00
2364	871	220-32224	legacy	2026-07-24 14:19:44.077972+00
2365	872	218-1983-L	legacy	2026-07-24 14:19:44.077972+00
2366	872	218-1983	legacy	2026-07-24 14:19:44.077972+00
2367	872	Stop VITARA Mod. 2015~2016~2017	legacy	2026-07-24 14:19:44.077972+00
2368	873	218-1983-R	legacy	2026-07-24 14:19:44.077972+00
2369	873	218-1983	legacy	2026-07-24 14:19:44.077972+00
2370	873	Stop VITARA Mod. 2015~2016~2017	legacy	2026-07-24 14:19:44.077972+00
2372	874	52-049-R	legacy	2026-07-24 14:19:44.077972+00
2373	874	Stop VITZ	legacy	2026-07-24 14:19:44.077972+00
2374	875	441-19C5	legacy	2026-07-24 14:19:44.077972+00
2375	875	441-19C5-L	legacy	2026-07-24 14:19:44.077972+00
2376	875	Stop Volkswagen SAVEIRO Mod. 2010~2011~2013~2014~2015	legacy	2026-07-24 14:19:44.077972+00
2377	876	441-19C5	legacy	2026-07-24 14:19:44.077972+00
2378	876	441-19C5-R	legacy	2026-07-24 14:19:44.077972+00
2379	876	Stop Volkswagen SAVEIRO Mod. 2010~2011~2013~2014~2015	legacy	2026-07-24 14:19:44.077972+00
2380	877	043-1563	legacy	2026-07-24 14:19:44.077972+00
2381	877	043-1563-L	legacy	2026-07-24 14:19:44.077972+00
2382	877	Stop-LANCER 92 214-1942	legacy	2026-07-24 14:19:44.077972+00
2383	878	DF12001	legacy	2026-07-24 14:19:44.077972+00
2384	878	Tacometro	legacy	2026-07-24 14:19:44.077972+00
2385	879	Tapa de TABLERO FORESTER 97-2000 FIBRA	legacy	2026-07-24 14:19:44.077972+00
2386	879	TT-FORESTER-F	legacy	2026-07-24 14:19:44.077972+00
2387	880	Tapabarro FORESTER Mod. 98~99~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
2388	880	SB11013A	legacy	2026-07-24 14:19:44.077972+00
2389	880	SB11013A-L	legacy	2026-07-24 14:19:44.077972+00
2390	881	Tapabarro FORESTER Mod. 98~99~2000~2001~2002	legacy	2026-07-24 14:19:44.077972+00
2391	881	SB11013A	legacy	2026-07-24 14:19:44.077972+00
2392	881	SB11013A-R	legacy	2026-07-24 14:19:44.077972+00
2393	882	3494-L	legacy	2026-07-24 14:19:44.077972+00
2394	882	TOYOTA EP82	legacy	2026-07-24 14:19:44.077972+00
2395	882	3494	legacy	2026-07-24 14:19:44.077972+00
2396	883	TOYOTA	legacy	2026-07-24 14:19:44.077972+00
2397	883	3485-R	legacy	2026-07-24 14:19:44.077972+00
2398	883	3485	legacy	2026-07-24 14:19:44.077972+00
2399	883	Starlet solei 91	legacy	2026-07-24 14:19:44.077972+00
2400	884	TURBO TD04	legacy	2026-07-24 14:19:44.077972+00
2401	884	TD-04	legacy	2026-07-24 14:19:44.077972+00
2402	885	4280	legacy	2026-07-24 14:19:44.077972+00
2403	885	VARIOS VERIFICAR	legacy	2026-07-24 14:19:44.077972+00
2404	885	4280-L	legacy	2026-07-24 14:19:44.077972+00
2405	886	Velocimetro SUBARU forester	legacy	2026-07-24 14:19:44.077972+00
2406	886	197001	legacy	2026-07-24 14:19:44.077972+00
2407	887	22002	legacy	2026-07-24 14:19:44.077972+00
2408	887	Velocimetro SUBARU impreza	legacy	2026-07-24 14:19:44.077972+00
2409	888	257500-3532	legacy	2026-07-24 14:19:44.077972+00
2410	888	Velocimetro SUBARU lite ace	legacy	2026-07-24 14:19:44.077972+00
2411	889	Bisel CORONA CON Media luz 212-1535	legacy	2026-07-24 14:19:44.077972+00
2412	889	20-93-R	legacy	2026-07-24 14:19:44.077972+00
2413	889	20-93	legacy	2026-07-24 14:19:44.077972+00
2414	890	53130-95J08	legacy	2026-07-24 14:19:44.077972+00
2415	890	Bisel CUSTOM 90 CROMADO	legacy	2026-07-24 14:19:44.077972+00
2416	890	53130-95J08-R	legacy	2026-07-24 14:19:44.077972+00
2417	891	53130-95J07	legacy	2026-07-24 14:19:44.077972+00
2418	891	Bisel CUSTOM 90 PLOMO	legacy	2026-07-24 14:19:44.077972+00
2419	891	53130-95J07-L	legacy	2026-07-24 14:19:44.077972+00
2420	892	Bisel NISSAN AD	legacy	2026-07-24 14:19:44.077972+00
2421	892	74071-60R00-L	legacy	2026-07-24 14:19:44.077972+00
2422	892	74071-60R00	legacy	2026-07-24 14:19:44.077972+00
2423	893	Bisel NISSAN AD	legacy	2026-07-24 14:19:44.077972+00
2424	893	74071-60R00	legacy	2026-07-24 14:19:44.077972+00
2425	893	74071-60R00-R	legacy	2026-07-24 14:19:44.077972+00
2426	894	62411	legacy	2026-07-24 14:19:44.077972+00
2427	894	62411-L	legacy	2026-07-24 14:19:44.077972+00
2428	894	Bisel NISSAN URVAN	legacy	2026-07-24 14:19:44.077972+00
2429	895	Espejo MITSUBISHI Montero Negro ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
2430	895	3686-N	legacy	2026-07-24 14:19:44.077972+00
2431	895	3686-N-L	legacy	2026-07-24 14:19:44.077972+00
2432	896	3686-N-R	legacy	2026-07-24 14:19:44.077972+00
2433	896	Espejo MITSUBISHI Montero Negro ELECTRICO	legacy	2026-07-24 14:19:44.077972+00
2434	896	3686-N	legacy	2026-07-24 14:19:44.077972+00
2435	897	VZV-32	legacy	2026-07-24 14:19:44.077972+00
2436	897	Espejo Toyota Camry 92	legacy	2026-07-24 14:19:44.077972+00
2437	897	VZV-32-L	legacy	2026-07-24 14:19:44.077972+00
2438	898	Espejo Toyota Varios	legacy	2026-07-24 14:19:44.077972+00
2439	898	G-35-L	legacy	2026-07-24 14:19:44.077972+00
2440	898	G-35	legacy	2026-07-24 14:19:44.077972+00
2441	899	G-35-R	legacy	2026-07-24 14:19:44.077972+00
2442	899	Espejo Toyota Varios	legacy	2026-07-24 14:19:44.077972+00
2443	899	G-35	legacy	2026-07-24 14:19:44.077972+00
2444	900	Espejo Honda varios	legacy	2026-07-24 14:19:44.077972+00
2445	900	1517	legacy	2026-07-24 14:19:44.077972+00
2446	900	1517-L	legacy	2026-07-24 14:19:44.077972+00
2447	901	5483-2	legacy	2026-07-24 14:19:44.077972+00
2448	901	Espejo Toyota Ipsum	legacy	2026-07-24 14:19:44.077972+00
2449	901	5483-2-R	legacy	2026-07-24 14:19:44.077972+00
2450	902	Espejo Toyota Mark 2	legacy	2026-07-24 14:19:44.077972+00
2451	902	1569	legacy	2026-07-24 14:19:44.077972+00
2452	902	1569-L	legacy	2026-07-24 14:19:44.077972+00
2453	903	Espejo Toyota Levin 92	legacy	2026-07-24 14:19:44.077972+00
2454	903	561327-R	legacy	2026-07-24 14:19:44.077972+00
2455	903	561327	legacy	2026-07-24 14:19:44.077972+00
2456	904	Espejo Honda Prelude 87-92	legacy	2026-07-24 14:19:44.077972+00
2457	904	2200	legacy	2026-07-24 14:19:44.077972+00
2458	904	2200-L	legacy	2026-07-24 14:19:44.077972+00
2630	971	TD-06	legacy	2026-07-24 14:19:44.077972+00
2459	905	Espejo Honda Prelude 87-92	legacy	2026-07-24 14:19:44.077972+00
2460	905	2200	legacy	2026-07-24 14:19:44.077972+00
2461	905	2200-R	legacy	2026-07-24 14:19:44.077972+00
2462	906	4675-2	legacy	2026-07-24 14:19:44.077972+00
2463	906	Espejo Nissan b14 Largo Eléctrico 3 pines	legacy	2026-07-24 14:19:44.077972+00
2464	906	4675-2-L	legacy	2026-07-24 14:19:44.077972+00
2465	907	4675-2	legacy	2026-07-24 14:19:44.077972+00
2466	907	4675-2-R	legacy	2026-07-24 14:19:44.077972+00
2467	907	Espejo Nissan b14 Largo Eléctrico 3 pines	legacy	2026-07-24 14:19:44.077972+00
2468	908	8247-R	legacy	2026-07-24 14:19:44.077972+00
2469	908	Espejo Nissan Pulsar eléctrico 3 pines	legacy	2026-07-24 14:19:44.077972+00
2470	908	8247	legacy	2026-07-24 14:19:44.077972+00
2471	909	5069	legacy	2026-07-24 14:19:44.077972+00
2472	909	Espejo Subaru Impreza	legacy	2026-07-24 14:19:44.077972+00
2473	909	5069-L	legacy	2026-07-24 14:19:44.077972+00
2474	910	5069-R	legacy	2026-07-24 14:19:44.077972+00
2475	910	Espejo Subaru Impreza	legacy	2026-07-24 14:19:44.077972+00
2476	910	5069	legacy	2026-07-24 14:19:44.077972+00
2477	911	EH-MITSUBISHI	legacy	2026-07-24 14:19:44.077972+00
2478	911	Estuché de herramientas Mitsubishi Negro	legacy	2026-07-24 14:19:44.077972+00
2479	912	Estuché de herramientas DAIHATSU azul	legacy	2026-07-24 14:19:44.077972+00
2480	912	EH-DAIHATSU	legacy	2026-07-24 14:19:44.077972+00
2481	913	Espejo Nissan e25 brazo cromado	legacy	2026-07-24 14:19:44.077972+00
2482	913	B38-C-L	legacy	2026-07-24 14:19:44.077972+00
2483	913	B38-C	legacy	2026-07-24 14:19:44.077972+00
2484	914	BU-SURF-F-L	legacy	2026-07-24 14:19:44.077972+00
2485	914	BU-SURF-F	legacy	2026-07-24 14:19:44.077972+00
2486	914	Buchera de fibra Hilux Surf	legacy	2026-07-24 14:19:44.077972+00
2487	915	220-75539-L	legacy	2026-07-24 14:19:44.077972+00
2488	915	Stop STARLET EP82 TURBO	legacy	2026-07-24 14:19:44.077972+00
2489	915	220-75539	legacy	2026-07-24 14:19:44.077972+00
2490	916	7362	legacy	2026-07-24 14:19:44.077972+00
2491	916	STOP TOYOTA CALDINA A MUELLE ROJO BLANCO	legacy	2026-07-24 14:19:44.077972+00
2492	916	7362-L	legacy	2026-07-24 14:19:44.077972+00
2493	917	7362-R	legacy	2026-07-24 14:19:44.077972+00
2494	917	STOP TOYOTA CALDINA A MUELLE ROJO BLANCO	legacy	2026-07-24 14:19:44.077972+00
2495	917	7362	legacy	2026-07-24 14:19:44.077972+00
2496	918	20-120-R	legacy	2026-07-24 14:19:44.077972+00
2497	918	20-120	legacy	2026-07-24 14:19:44.077972+00
2498	918	STOP TOYOTA CORONA 1983 (rojo / Naranja)	legacy	2026-07-24 14:19:44.077972+00
2499	919	7157	legacy	2026-07-24 14:19:44.077972+00
2500	919	Stop CARIB 80	legacy	2026-07-24 14:19:44.077972+00
2501	919	7157-R	legacy	2026-07-24 14:19:44.077972+00
2502	920	TD-30-L	legacy	2026-07-24 14:19:44.077972+00
2503	920	TD-30	legacy	2026-07-24 14:19:44.077972+00
2504	920	EMBELLECEDOR DE MALETERO MITSUBISHI LANCER EVO 6	legacy	2026-07-24 14:19:44.077972+00
2505	921	TD-30-R	legacy	2026-07-24 14:19:44.077972+00
2506	921	TD-30	legacy	2026-07-24 14:19:44.077972+00
2507	921	EMBELLECEDOR DE MALETERO MITSUBISHI LANCER EVO 6	legacy	2026-07-24 14:19:44.077972+00
2508	922	1159	legacy	2026-07-24 14:19:44.077972+00
2509	922	Farol Toyota Varios	legacy	2026-07-24 14:19:44.077972+00
2510	922	1159-R	legacy	2026-07-24 14:19:44.077972+00
2511	923	212-1166	legacy	2026-07-24 14:19:44.077972+00
2512	923	Farol Toyota. rav 4 97	legacy	2026-07-24 14:19:44.077972+00
2513	923	212-1166-L	legacy	2026-07-24 14:19:44.077972+00
2514	924	212-1166	legacy	2026-07-24 14:19:44.077972+00
2515	924	212-1166-R	legacy	2026-07-24 14:19:44.077972+00
2516	924	Farol Toyota. rav 4 97	legacy	2026-07-24 14:19:44.077972+00
2517	925	Stop BLUBIRT 96	legacy	2026-07-24 14:19:44.077972+00
2518	925	47-59	legacy	2026-07-24 14:19:44.077972+00
2519	925	47-59-L	legacy	2026-07-24 14:19:44.077972+00
2520	926	FAROL TOYOTASPACIO	legacy	2026-07-24 14:19:44.077972+00
2521	926	13-38	legacy	2026-07-24 14:19:44.077972+00
2522	926	13-38-L	legacy	2026-07-24 14:19:44.077972+00
2523	927	Farol Toyota Spacio	legacy	2026-07-24 14:19:44.077972+00
2524	927	13-38-R	legacy	2026-07-24 14:19:44.077972+00
2525	927	13-38	legacy	2026-07-24 14:19:44.077972+00
2526	928	215-1129	legacy	2026-07-24 14:19:44.077972+00
2527	928	215-1129-L	legacy	2026-07-24 14:19:44.077972+00
2528	929	215-1129	legacy	2026-07-24 14:19:44.077972+00
2529	929	215-1129-R	legacy	2026-07-24 14:19:44.077972+00
2530	930	212-1112-TYC	legacy	2026-07-24 14:19:44.077972+00
2531	930	212-1112-TYC-L	legacy	2026-07-24 14:19:44.077972+00
2532	930	Farol Toyota COROLLA 90 CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2533	931	212-1112-TYC-R	legacy	2026-07-24 14:19:44.077972+00
2534	931	212-1112-TYC	legacy	2026-07-24 14:19:44.077972+00
2535	931	Farol Toyota COROLLA 90 CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2536	932	212-1112	legacy	2026-07-24 14:19:44.077972+00
2537	932	212-1112-L	legacy	2026-07-24 14:19:44.077972+00
2538	933	212-1112	legacy	2026-07-24 14:19:44.077972+00
2539	933	212-1112-R	legacy	2026-07-24 14:19:44.077972+00
2540	934	FAROL NISSAN SUNNY 2005	legacy	2026-07-24 14:19:44.077972+00
2541	934	1602	legacy	2026-07-24 14:19:44.077972+00
2542	934	1602-L	legacy	2026-07-24 14:19:44.077972+00
2543	935	FAROL NISSAN SUNNY 2005	legacy	2026-07-24 14:19:44.077972+00
2544	935	1602	legacy	2026-07-24 14:19:44.077972+00
2545	935	1602-R	legacy	2026-07-24 14:19:44.077972+00
2546	936	FAROL MAZDA BONGO SGL5 95	legacy	2026-07-24 14:19:44.077972+00
2547	936	001-6840	legacy	2026-07-24 14:19:44.077972+00
2548	936	001-6840-L	legacy	2026-07-24 14:19:44.077972+00
2549	937	FAROL MAZDA BONGO SGL5 95	legacy	2026-07-24 14:19:44.077972+00
2550	937	001-6840	legacy	2026-07-24 14:19:44.077972+00
2551	937	001-6840-R	legacy	2026-07-24 14:19:44.077972+00
2552	938	BICEL MITSUBISHI MONTERO 90	legacy	2026-07-24 14:19:44.077972+00
2553	938	214-1203	legacy	2026-07-24 14:19:44.077972+00
2554	938	214-1203-R	legacy	2026-07-24 14:19:44.077972+00
2555	939	214-1128	legacy	2026-07-24 14:19:44.077972+00
2556	939	214-1128-L	legacy	2026-07-24 14:19:44.077972+00
2557	940	214-1128	legacy	2026-07-24 14:19:44.077972+00
2558	940	214-1128-R	legacy	2026-07-24 14:19:44.077972+00
2559	941	4413	legacy	2026-07-24 14:19:44.077972+00
2560	941	4413-L	legacy	2026-07-24 14:19:44.077972+00
2561	941	FAROL TOYOTA GAIA	legacy	2026-07-24 14:19:44.077972+00
2562	942	4413-R	legacy	2026-07-24 14:19:44.077972+00
2563	942	4413	legacy	2026-07-24 14:19:44.077972+00
2564	942	FAROL TOYOTA GAIA	legacy	2026-07-24 14:19:44.077972+00
2565	943	2650-L	legacy	2026-07-24 14:19:44.077972+00
2566	943	FAROL TOYOTA GRANVIA	legacy	2026-07-24 14:19:44.077972+00
2567	943	2650	legacy	2026-07-24 14:19:44.077972+00
2568	944	FAROL TOYOTA GRANVIA	legacy	2026-07-24 14:19:44.077972+00
2569	944	2650-R	legacy	2026-07-24 14:19:44.077972+00
2570	944	2650	legacy	2026-07-24 14:19:44.077972+00
2571	945	P0286-L	legacy	2026-07-24 14:19:44.077972+00
2572	945	P0286	legacy	2026-07-24 14:19:44.077972+00
2573	946	P0286-R	legacy	2026-07-24 14:19:44.077972+00
2574	946	P0286	legacy	2026-07-24 14:19:44.077972+00
2575	947	212-1105	legacy	2026-07-24 14:19:44.077972+00
2576	947	212-1105-L	legacy	2026-07-24 14:19:44.077972+00
2577	948	212-1105-R	legacy	2026-07-24 14:19:44.077972+00
2578	948	212-1105	legacy	2026-07-24 14:19:44.077972+00
2579	949	CP-DOMINGO	legacy	2026-07-24 14:19:44.077972+00
2580	949	COLA DE PATO SUBARU DOMINGO	legacy	2026-07-24 14:19:44.077972+00
2581	950	CP-MIT-GRANDIS	legacy	2026-07-24 14:19:44.077972+00
2582	950	COLA DE PATO MITSUBISHI GRANDIS	legacy	2026-07-24 14:19:44.077972+00
2583	951	VI-S-DOM-89-F	legacy	2026-07-24 14:19:44.077972+00
2584	951	BISEL SUBARU DOMINGO RASPADILLO ( FIBRA )	legacy	2026-07-24 14:19:44.077972+00
2585	951	VI-S-DOM-89-F-L	legacy	2026-07-24 14:19:44.077972+00
2586	952	VI-S-DOM-89-F	legacy	2026-07-24 14:19:44.077972+00
2587	952	BISEL SUBARU DOMINGO RASPADILLO (FIBRA )	legacy	2026-07-24 14:19:44.077972+00
2588	952	VI-S-DOM-89-F-R	legacy	2026-07-24 14:19:44.077972+00
2589	953	VI-S-DOM-89-F-L	legacy	2026-07-24 14:19:44.077972+00
2590	953	VI-S-DOM-89-F	legacy	2026-07-24 14:19:44.077972+00
2591	953	BISEL SUBARU DOMINGO RASPADILLO JAPONÉS	legacy	2026-07-24 14:19:44.077972+00
2592	954	VI-S-DOM-89-F	legacy	2026-07-24 14:19:44.077972+00
2593	954	VI-S-DOM-89-F-R	legacy	2026-07-24 14:19:44.077972+00
2594	954	BISEL SUBARU DOMINGO RASPADILLO JAPONÉS	legacy	2026-07-24 14:19:44.077972+00
2595	955	JALADOR DE PUERTA TRASERA TOYOTA CALDINA GT	legacy	2026-07-24 14:19:44.077972+00
2596	955	J-TOY-CALGT-F	legacy	2026-07-24 14:19:44.077972+00
2597	956	212-1592-B-K	legacy	2026-07-24 14:19:44.077972+00
2598	956	GUIÑADOR TOYOTA COROLLA SAPITO NEGRO	legacy	2026-07-24 14:19:44.077972+00
2599	956	212-1592-B-K-L	legacy	2026-07-24 14:19:44.077972+00
2600	957	212-1592-B-K	legacy	2026-07-24 14:19:44.077972+00
2601	957	GUIÑADOR TOYOTA COROLLA SAPITO NEGRO	legacy	2026-07-24 14:19:44.077972+00
2602	957	212-1592-B-K-R	legacy	2026-07-24 14:19:44.077972+00
2603	958	212-1126-L	legacy	2026-07-24 14:19:44.077972+00
2604	958	212-1126	legacy	2026-07-24 14:19:44.077972+00
2605	959	20-316-L	legacy	2026-07-24 14:19:44.077972+00
2606	959	20-316	legacy	2026-07-24 14:19:44.077972+00
2607	960	1266-L	legacy	2026-07-24 14:19:44.077972+00
2608	960	1266	legacy	2026-07-24 14:19:44.077972+00
2609	961	216-1139	legacy	2026-07-24 14:19:44.077972+00
2610	961	216-1139-R	legacy	2026-07-24 14:19:44.077972+00
2611	962	20-143-L	legacy	2026-07-24 14:19:44.077972+00
2612	962	20-143	legacy	2026-07-24 14:19:44.077972+00
2613	963	12-417-L	legacy	2026-07-24 14:19:44.077972+00
2614	963	12-417	legacy	2026-07-24 14:19:44.077972+00
2615	964	MASACARA TOYOTA RAV 4 TRD	legacy	2026-07-24 14:19:44.077972+00
2616	964	08423-42040	legacy	2026-07-24 14:19:44.077972+00
2617	965	71741-80G00	legacy	2026-07-24 14:19:44.077972+00
2618	965	MASCARA SUZUKI SWIFT IGNIS	legacy	2026-07-24 14:19:44.077972+00
2619	966	62310-N00	legacy	2026-07-24 14:19:44.077972+00
2620	966	MASCARA NISSAAN CUSTOM CROMADO	legacy	2026-07-24 14:19:44.077972+00
2621	967	PALOGENOS-MIT-JUN	legacy	2026-07-24 14:19:44.077972+00
2622	967	PORTA ALÓGENOS MITSUBISHI JUNIOR SOBRE EL PARACHOQUE	legacy	2026-07-24 14:19:44.077972+00
2623	968	F-TSU-SUB-FOR	legacy	2026-07-24 14:19:44.077972+00
2624	968	TOMA DE AIRE TSUNAMI SUBARU FORESTER	legacy	2026-07-24 14:19:44.077972+00
2625	969	TOMA DE AIRE TSUNAMI SUBARU IMPREZA	legacy	2026-07-24 14:19:44.077972+00
2626	969	F-TSU-SUB-IMP	legacy	2026-07-24 14:19:44.077972+00
2627	970	C-TSU-SUB-UNI	legacy	2026-07-24 14:19:44.077972+00
2628	970	TOMA DE AIRE TSUNAMI UNIVERSAL CARBONO	legacy	2026-07-24 14:19:44.077972+00
2629	971	TURBO NUEVO SUBARU EJ20 TURBO	legacy	2026-07-24 14:19:44.077972+00
2631	972	212-1156	legacy	2026-07-24 14:19:44.077972+00
2632	972	212-1156-L	legacy	2026-07-24 14:19:44.077972+00
2633	972	FAROL TOYOTA CALDINA 97 ( oreja agachada )	legacy	2026-07-24 14:19:44.077972+00
2634	973	212-1156	legacy	2026-07-24 14:19:44.077972+00
2635	973	FAROL TOYOTA CALDINA 97 ( oreja agachada )	legacy	2026-07-24 14:19:44.077972+00
2636	973	212-1156-R	legacy	2026-07-24 14:19:44.077972+00
2637	974	20-260-R	legacy	2026-07-24 14:19:44.077972+00
2638	974	20-260	legacy	2026-07-24 14:19:44.077972+00
2639	975	Cola DE PATO SUBARU FORESTER 2000 JAPONÉS	legacy	2026-07-24 14:19:44.077972+00
2640	975	CP-SUB-FOR-OEM	legacy	2026-07-24 14:19:44.077972+00
2641	976	Stop COROLLA 89	legacy	2026-07-24 14:19:44.077972+00
2642	976	13-29	legacy	2026-07-24 14:19:44.077972+00
2643	976	13-29-L	legacy	2026-07-24 14:19:44.077972+00
2644	977	STOP DE MALETERA MITSUBISHI MONTERO (terecera luz )	legacy	2026-07-24 14:19:44.077972+00
2645	977	OEW2037	legacy	2026-07-24 14:19:44.077972+00
2646	978	221-1975-L	legacy	2026-07-24 14:19:44.077972+00
2647	978	221-1975	legacy	2026-07-24 14:19:44.077972+00
2648	978	STOP HYUNDAI I10 2011-2012	legacy	2026-07-24 14:19:44.077972+00
2649	979	221-1975-R	legacy	2026-07-24 14:19:44.077972+00
2650	979	221-1975	legacy	2026-07-24 14:19:44.077972+00
2651	979	STOP HYUNDAI I10 2011-2012	legacy	2026-07-24 14:19:44.077972+00
2652	980	221-1979	legacy	2026-07-24 14:19:44.077972+00
2653	980	221-1979-L	legacy	2026-07-24 14:19:44.077972+00
2654	980	STOP HYUNDAI I10 2014-2016	legacy	2026-07-24 14:19:44.077972+00
2655	981	315-1934-PTU-VC	legacy	2026-07-24 14:19:44.077972+00
2656	981	SET	legacy	2026-07-24 14:19:44.077972+00
2657	982	STOP SUZUKI VITARA XL7 CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2658	982	218-1937	legacy	2026-07-24 14:19:44.077972+00
2659	982	218-1937-L	legacy	2026-07-24 14:19:44.077972+00
2660	983	STOP SUZUKI VITARA XL7 CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2661	983	218-1937-R	legacy	2026-07-24 14:19:44.077972+00
2662	983	218-1937	legacy	2026-07-24 14:19:44.077972+00
2663	984	212-19F1-PTA	legacy	2026-07-24 14:19:44.077972+00
2664	984	SET	legacy	2026-07-24 14:19:44.077972+00
2665	985	STOP MAZDA BT50 2015	legacy	2026-07-24 14:19:44.077972+00
2666	985	216-19AG-L	legacy	2026-07-24 14:19:44.077972+00
2667	985	216-19AG	legacy	2026-07-24 14:19:44.077972+00
2668	986	STOP MAZDA BT50 2015	legacy	2026-07-24 14:19:44.077972+00
2669	986	216-19AG	legacy	2026-07-24 14:19:44.077972+00
2670	986	216-19AG-R	legacy	2026-07-24 14:19:44.077972+00
2671	987	214-1140	legacy	2026-07-24 14:19:44.077972+00
2672	987	214-1140-L	legacy	2026-07-24 14:19:44.077972+00
2673	987	FAROL MITSUBISHI LANCER 95	legacy	2026-07-24 14:19:44.077972+00
2674	988	214-1140	legacy	2026-07-24 14:19:44.077972+00
2675	988	214-1140-R	legacy	2026-07-24 14:19:44.077972+00
2676	988	FAROL MITSUBISHI LANCER 95	legacy	2026-07-24 14:19:44.077972+00
2677	989	218-1164-R	legacy	2026-07-24 14:19:44.077972+00
2678	989	218-1164	legacy	2026-07-24 14:19:44.077972+00
2679	990	214-1556-L	legacy	2026-07-24 14:19:44.077972+00
2680	990	214-1556	legacy	2026-07-24 14:19:44.077972+00
2681	990	Media luz MITSUBISHI pajero 96	legacy	2026-07-24 14:19:44.077972+00
2682	991	214-1556-R	legacy	2026-07-24 14:19:44.077972+00
2683	991	Media luz MITSUBISHI pajero 96	legacy	2026-07-24 14:19:44.077972+00
2684	991	214-1556	legacy	2026-07-24 14:19:44.077972+00
2685	992	FAROL TOYOTA HILUX VIGO 2011	legacy	2026-07-24 14:19:44.077972+00
2686	992	212-11T2	legacy	2026-07-24 14:19:44.077972+00
2687	992	212-11T2-R	legacy	2026-07-24 14:19:44.077972+00
2688	993	215-1427-R	legacy	2026-07-24 14:19:44.077972+00
2689	993	Media luz Nissan patrol 95	legacy	2026-07-24 14:19:44.077972+00
2690	993	215-1427	legacy	2026-07-24 14:19:44.077972+00
2691	994	217-1531	legacy	2026-07-24 14:19:44.077972+00
2692	994	MIEDIA LUZ HONDA CIVIC 88	legacy	2026-07-24 14:19:44.077972+00
2693	994	217-1531-L	legacy	2026-07-24 14:19:44.077972+00
2694	995	217-1531	legacy	2026-07-24 14:19:44.077972+00
2695	995	MIEDIA LUZ HONDA CIVIC 88	legacy	2026-07-24 14:19:44.077972+00
2696	995	217-1531-R	legacy	2026-07-24 14:19:44.077972+00
2697	996	218-1151-L	legacy	2026-07-24 14:19:44.077972+00
2698	996	218-1151	legacy	2026-07-24 14:19:44.077972+00
2699	996	FAROL SUZUKI SWIFT 2011-2016	legacy	2026-07-24 14:19:44.077972+00
2700	997	218-1151-R	legacy	2026-07-24 14:19:44.077972+00
2701	997	218-1151	legacy	2026-07-24 14:19:44.077972+00
2702	997	FAROL SUZUKI SWIFT 2011-2016	legacy	2026-07-24 14:19:44.077972+00
2703	998	REFLECTOR FJ40	legacy	2026-07-24 14:19:44.077972+00
2704	998	212-2901N	legacy	2026-07-24 14:19:44.077972+00
2705	999	314-1132-PXAS2-L	legacy	2026-07-24 14:19:44.077972+00
2706	999	314-1132-PXAS2	legacy	2026-07-24 14:19:44.077972+00
2707	999	FAROL MITSUBISHI ECLIPSE SPYDER OJO DE ÁNGEL	legacy	2026-07-24 14:19:44.077972+00
2708	1000	314-1132-PXAS2-R	legacy	2026-07-24 14:19:44.077972+00
2709	1000	314-1132-PXAS2	legacy	2026-07-24 14:19:44.077972+00
2710	1000	FAROL MITSUBISHI ECLIPSE SPYDER OJO DE ÁNGEL	legacy	2026-07-24 14:19:44.077972+00
2711	1001	860074	legacy	2026-07-24 14:19:44.077972+00
2712	1002	870107-O	legacy	2026-07-24 14:19:44.077972+00
2713	1003	87005-G	legacy	2026-07-24 14:19:44.077972+00
2714	1004	87006-G	legacy	2026-07-24 14:19:44.077972+00
2715	1005	87009-G	legacy	2026-07-24 14:19:44.077972+00
2716	1006	870121-G	legacy	2026-07-24 14:19:44.077972+00
2717	1007	PRENSA EXEDY SUZUKI APV	legacy	2026-07-24 14:19:44.077972+00
2718	1007	SZC-527	legacy	2026-07-24 14:19:44.077972+00
2719	1008	MBD-005U	legacy	2026-07-24 14:19:44.077972+00
2720	1008	DISCO DE EMBREAGUE EXEDY SUZUKI APV	legacy	2026-07-24 14:19:44.077972+00
2721	1009	T-NISS-STOP-F-L	legacy	2026-07-24 14:19:44.077972+00
2722	1009	TAPA DE STOP NISSAN CUSTOM FIBRA	legacy	2026-07-24 14:19:44.077972+00
2723	1009	T-NISS-STOP-F	legacy	2026-07-24 14:19:44.077972+00
2724	1010	T-NISS-STOP-F-R	legacy	2026-07-24 14:19:44.077972+00
2725	1010	TAPA DE STOP NISSAN CUSTOM FIBRA	legacy	2026-07-24 14:19:44.077972+00
2726	1010	T-NISS-STOP-F	legacy	2026-07-24 14:19:44.077972+00
2727	1011	400300	legacy	2026-07-24 14:19:44.077972+00
2728	1012	CH-216071	legacy	2026-07-24 14:19:44.077972+00
2729	1013	MB574333	legacy	2026-07-24 14:19:44.077972+00
2730	1013	PARACHOQUE TRASERO MITSUBISHI EVO 9	legacy	2026-07-24 14:19:44.077972+00
2731	1014	71811-65D30	legacy	2026-07-24 14:19:44.077972+00
2732	1014	PARACHOQUE TRASERO SUZUKI GRAN VITARA	legacy	2026-07-24 14:19:44.077972+00
2733	1015	YY213M-L	legacy	2026-07-24 14:19:44.077972+00
2734	1015	ESPEJO B13	legacy	2026-07-24 14:19:44.077972+00
2735	1015	YY213M	legacy	2026-07-24 14:19:44.077972+00
2736	1016	ELSEJO B13	legacy	2026-07-24 14:19:44.077972+00
2737	1016	YY213M-R	legacy	2026-07-24 14:19:44.077972+00
2738	1016	YY213M	legacy	2026-07-24 14:19:44.077972+00
2739	1017	TY8002B	legacy	2026-07-24 14:19:44.077972+00
2740	1017	RETROVISOR TOYOTA HILUX MILENIUM CROMADO	legacy	2026-07-24 14:19:44.077972+00
2741	1017	TY8002B-L	legacy	2026-07-24 14:19:44.077972+00
2742	1018	222110	legacy	2026-07-24 14:19:44.077972+00
2743	1018	222110-L	legacy	2026-07-24 14:19:44.077972+00
2744	1019	ESPEJO TOYOTA HILUX VIGO ELÉCTRICO	legacy	2026-07-24 14:19:44.077972+00
2745	1019	TY8022	legacy	2026-07-24 14:19:44.077972+00
2746	1019	TY8022-L	legacy	2026-07-24 14:19:44.077972+00
2747	1020	ESPEJO SUZUKI ALTO 2011	legacy	2026-07-24 14:19:44.077972+00
2748	1020	YT7286	legacy	2026-07-24 14:19:44.077972+00
2749	1020	YT7286-L	legacy	2026-07-24 14:19:44.077972+00
2750	1021	ESPEJO SUZUKI ALTO 2011	legacy	2026-07-24 14:19:44.077972+00
2751	1021	YT7286-R	legacy	2026-07-24 14:19:44.077972+00
2752	1021	YT7286	legacy	2026-07-24 14:19:44.077972+00
2753	1022	219-1405-L	legacy	2026-07-24 14:19:44.077972+00
2754	1022	219-1405	legacy	2026-07-24 14:19:44.077972+00
2755	1023	219-1405-R	legacy	2026-07-24 14:19:44.077972+00
2756	1023	219-1405	legacy	2026-07-24 14:19:44.077972+00
2757	1024	Am0709-L	legacy	2026-07-24 14:19:44.077972+00
2758	1024	Am0709	legacy	2026-07-24 14:19:44.077972+00
2759	1024	Jeep Cherokee vicel	legacy	2026-07-24 14:19:44.077972+00
2760	1025	215-1977	legacy	2026-07-24 14:19:44.077972+00
2761	1026	220-6693-L	legacy	2026-07-24 14:19:44.077972+00
2762	1026	220-6693	legacy	2026-07-24 14:19:44.077972+00
2763	1026	STOP NISSAN SKYLINE	legacy	2026-07-24 14:19:44.077972+00
2764	1027	220-6693	legacy	2026-07-24 14:19:44.077972+00
2765	1027	220-6693-R	legacy	2026-07-24 14:19:44.077972+00
2766	1027	STOP NISSAN SKYLINE	legacy	2026-07-24 14:19:44.077972+00
2767	1028	215-19AA	legacy	2026-07-24 14:19:44.077972+00
2768	1028	215-19AA-L	legacy	2026-07-24 14:19:44.077972+00
2769	1029	SZ04092BA	legacy	2026-07-24 14:19:44.077972+00
2770	1030	SZ07067GA	legacy	2026-07-24 14:19:44.077972+00
2771	1031	SZ99020AL	legacy	2026-07-24 14:19:44.077972+00
2772	1032	SZ99020AR	legacy	2026-07-24 14:19:44.077972+00
2773	1033	EM-FORESTER-C	legacy	2026-07-24 14:19:44.077972+00
2774	1033	Embellecedor FORESTER CARBONO	legacy	2026-07-24 14:19:44.077972+00
2775	1034	CANDADO DE MOTO / SCOOTER ELÉCTRICO	legacy	2026-07-24 14:19:44.077972+00
2776	1034	FS8305	legacy	2026-07-24 14:19:44.077972+00
2777	1035	SZ11036A-L	legacy	2026-07-24 14:19:44.077972+00
2778	1035	SZ11036A	legacy	2026-07-24 14:19:44.077972+00
2779	1035	GUARDABARRO SUZUKI VITARA	legacy	2026-07-24 14:19:44.077972+00
2780	1036	SZ11036A-R	legacy	2026-07-24 14:19:44.077972+00
2781	1036	SZ11036A	legacy	2026-07-24 14:19:44.077972+00
2782	1036	GUARDABARRO SUZUKI VITARA	legacy	2026-07-24 14:19:44.077972+00
2783	1037	Guiñador honda eg negro	legacy	2026-07-24 14:19:44.077972+00
2784	1037	217-1516	legacy	2026-07-24 14:19:44.077972+00
2785	1037	217-1516-L	legacy	2026-07-24 14:19:44.077972+00
2786	1038	Guiñador honda eg negro	legacy	2026-07-24 14:19:44.077972+00
2787	1038	217-1516	legacy	2026-07-24 14:19:44.077972+00
2788	1038	217-1516-R	legacy	2026-07-24 14:19:44.077972+00
2789	1039	212-1592-R	legacy	2026-07-24 14:19:44.077972+00
2790	1039	212-1592	legacy	2026-07-24 14:19:44.077972+00
2791	1039	Media luz COROLLA Mod. 95 ~ 96 AE110. SAPITO	legacy	2026-07-24 14:19:44.077972+00
2792	1040	212-1670	legacy	2026-07-24 14:19:44.077972+00
2793	1040	212-1670-L	legacy	2026-07-24 14:19:44.077972+00
2794	1041	FAROL TOYOTA RAV 4 99	legacy	2026-07-24 14:19:44.077972+00
2795	1041	312-1141	legacy	2026-07-24 14:19:44.077972+00
2796	1041	312-1141-L	legacy	2026-07-24 14:19:44.077972+00
2797	1042	FAROL TOYOTA RAV 4 99	legacy	2026-07-24 14:19:44.077972+00
2798	1042	312-1141-R	legacy	2026-07-24 14:19:44.077972+00
2799	1042	312-1141	legacy	2026-07-24 14:19:44.077972+00
2800	1043	FAROL NISSAN SUNNY B12	legacy	2026-07-24 14:19:44.077972+00
2801	1043	215-1111	legacy	2026-07-24 14:19:44.077972+00
2802	1043	215-1111-R	legacy	2026-07-24 14:19:44.077972+00
2803	1044	218-1105-L	legacy	2026-07-24 14:19:44.077972+00
2804	1044	218-1105	legacy	2026-07-24 14:19:44.077972+00
2805	1045	218-1105-R	legacy	2026-07-24 14:19:44.077972+00
2806	1045	218-1105	legacy	2026-07-24 14:19:44.077972+00
2807	1046	312-1186	legacy	2026-07-24 14:19:44.077972+00
2808	1046	312-1186-L	legacy	2026-07-24 14:19:44.077972+00
2809	1047	870043	legacy	2026-07-24 14:19:44.077972+00
2810	1047	AMORTIGUADOR PROBOX	legacy	2026-07-24 14:19:44.077972+00
2811	1048	870090	legacy	2026-07-24 14:19:44.077972+00
2812	1048	AMORTIGUADOR APV	legacy	2026-07-24 14:19:44.077972+00
2813	1049	870052-O	legacy	2026-07-24 14:19:44.077972+00
2814	1050	AMORTIGUADORDELANTERO HILUX STAU	legacy	2026-07-24 14:19:44.077972+00
2815	1050	DS-2007	legacy	2026-07-24 14:19:44.077972+00
2816	1051	MASCARA TOYOTA RAV 4 FIBRA DE VIDRIO	legacy	2026-07-24 14:19:44.077972+00
2817	1051	M-TOY-rav-f	legacy	2026-07-24 14:19:44.077972+00
2818	1052	AMORTIGUADOR CHARIOT	legacy	2026-07-24 14:19:44.077972+00
2819	1052	870104-G	legacy	2026-07-24 14:19:44.077972+00
2820	1053	860009	legacy	2026-07-24 14:19:44.077972+00
2821	1053	MUÑÓN ESTABILIZADOR LARGO UNIVERSAL	legacy	2026-07-24 14:19:44.077972+00
2822	1054	860044	legacy	2026-07-24 14:19:44.077972+00
2823	1054	MUÑÓN SUSPENCION SUPERIRO HIACE LOBO	legacy	2026-07-24 14:19:44.077972+00
2824	1055	RODAMIENTO SUBARU EJ 20 SIN TURBO	legacy	2026-07-24 14:19:44.077972+00
2825	1055	30502-AA051	legacy	2026-07-24 14:19:44.077972+00
2826	1056	860051	legacy	2026-07-24 14:19:44.077972+00
2827	1056	MUÑÓN SUSPENCION TOYOTA TERCEL	legacy	2026-07-24 14:19:44.077972+00
2828	1057	860061	legacy	2026-07-24 14:19:44.077972+00
2829	1057	MUÑÓN SUSPENCION VANNETE BONGO INFERIOR MAZDA	legacy	2026-07-24 14:19:44.077972+00
2830	1058	850022	legacy	2026-07-24 14:19:44.077972+00
2831	1058	JUNTA 24X23 TOY PROBOX	legacy	2026-07-24 14:19:44.077972+00
2832	1059	214-1146	legacy	2026-07-24 14:19:44.077972+00
2833	1059	FAROL MITSUBISHI MONTERO CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2834	1059	214-1146-L	legacy	2026-07-24 14:19:44.077972+00
2835	1060	214-1146-R	legacy	2026-07-24 14:19:44.077972+00
2836	1060	214-1146	legacy	2026-07-24 14:19:44.077972+00
2837	1060	FAROL MITSUBISHI MONTERO CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2838	1061	123629	legacy	2026-07-24 14:19:44.077972+00
2839	1061	RÓTULA HIACE LOBO 14X17	legacy	2026-07-24 14:19:44.077972+00
2840	1062	214-11A7	legacy	2026-07-24 14:19:44.077972+00
2841	1062	FAROL MITSUBISHI MIRAGE	legacy	2026-07-24 14:19:44.077972+00
2842	1062	214-11A7-R	legacy	2026-07-24 14:19:44.077972+00
2843	1063	Guiñador subaru forester	legacy	2026-07-24 14:19:44.077972+00
2844	1063	320-1506	legacy	2026-07-24 14:19:44.077972+00
2845	1063	320-1506-R	legacy	2026-07-24 14:19:44.077972+00
2846	1064	FAROL MITSUBISHI COLT 87	legacy	2026-07-24 14:19:44.077972+00
2847	1064	214-1112-L	legacy	2026-07-24 14:19:44.077972+00
2848	1064	214-1112	legacy	2026-07-24 14:19:44.077972+00
2849	1065	218-1172-L	legacy	2026-07-24 14:19:44.077972+00
2850	1065	218-1172	legacy	2026-07-24 14:19:44.077972+00
2851	1066	218-1172-R	legacy	2026-07-24 14:19:44.077972+00
2852	1066	218-1172	legacy	2026-07-24 14:19:44.077972+00
2853	1067	STOP MITSUBISHI MONTERO BORDE NEGRO	legacy	2026-07-24 14:19:44.077972+00
2854	1067	043-1540-L	legacy	2026-07-24 14:19:44.077972+00
2855	1067	043-1540	legacy	2026-07-24 14:19:44.077972+00
2856	1068	STOP MITSUBISHI MONTERO BORDE NEGRO	legacy	2026-07-24 14:19:44.077972+00
2857	1068	043-1540	legacy	2026-07-24 14:19:44.077972+00
2858	1068	043-1540-R	legacy	2026-07-24 14:19:44.077972+00
2859	1069	210-87071	legacy	2026-07-24 14:19:44.077972+00
2860	1069	210-87071-R	legacy	2026-07-24 14:19:44.077972+00
2861	1070	215-1968-PXA-L	legacy	2026-07-24 14:19:44.077972+00
2862	1070	STOP CRISTALIZADO NISSAN PATROL	legacy	2026-07-24 14:19:44.077972+00
2863	1070	215-1968-PXA	legacy	2026-07-24 14:19:44.077972+00
2864	1071	STOP CRISTALIZADO NISSAN PATROL	legacy	2026-07-24 14:19:44.077972+00
2865	1071	215-1968-PXA	legacy	2026-07-24 14:19:44.077972+00
2866	1071	215-1968-PXA-R	legacy	2026-07-24 14:19:44.077972+00
2867	1072	212-1915	legacy	2026-07-24 14:19:44.077972+00
2868	1072	212-1915-L	legacy	2026-07-24 14:19:44.077972+00
2869	1073	215-1993-R	legacy	2026-07-24 14:19:44.077972+00
2870	1073	215-1993	legacy	2026-07-24 14:19:44.077972+00
2871	1074	215-1993	legacy	2026-07-24 14:19:44.077972+00
2872	1074	215-1993-L	legacy	2026-07-24 14:19:44.077972+00
2873	1075	317-1513-L	legacy	2026-07-24 14:19:44.077972+00
2874	1075	317-1513	legacy	2026-07-24 14:19:44.077972+00
2875	1076	317-1513-R	legacy	2026-07-24 14:19:44.077972+00
2876	1076	317-1513	legacy	2026-07-24 14:19:44.077972+00
2877	1077	330-1504-R	legacy	2026-07-24 14:19:44.077972+00
2878	1077	330-1504	legacy	2026-07-24 14:19:44.077972+00
2879	1078	TAPABARRO HILUX SURF	legacy	2026-07-24 14:19:44.077972+00
2880	1078	TY11106	legacy	2026-07-24 14:19:44.077972+00
2881	1079	FAROL VOLKSWAGEN OJO DE ÁNGEL	legacy	2026-07-24 14:19:44.077972+00
2882	1079	441-1177	legacy	2026-07-24 14:19:44.077972+00
2883	1080	Guiñador pick up	legacy	2026-07-24 14:19:44.077972+00
2884	1080	215-1504-L	legacy	2026-07-24 14:19:44.077972+00
2885	1080	215-1504	legacy	2026-07-24 14:19:44.077972+00
2886	1081	215-1504-R	legacy	2026-07-24 14:19:44.077972+00
2887	1081	Guiñador PICK UP	legacy	2026-07-24 14:19:44.077972+00
2888	1081	215-1504	legacy	2026-07-24 14:19:44.077972+00
2889	1082	Stop BONGO	legacy	2026-07-24 14:19:44.077972+00
2890	1082	220-61871-L	legacy	2026-07-24 14:19:44.077972+00
2891	1082	220-61871	legacy	2026-07-24 14:19:44.077972+00
2892	1083	Farol NISSAN SUNNY b12	legacy	2026-07-24 14:19:44.077972+00
2893	1083	1188	legacy	2026-07-24 14:19:44.077972+00
2894	1083	1188-L	legacy	2026-07-24 14:19:44.077972+00
2895	1084	212-11AK-L	legacy	2026-07-24 14:19:44.077972+00
2896	1084	FAROL TOYOTA HILUX REVO	legacy	2026-07-24 14:19:44.077972+00
2897	1084	212-11AK	legacy	2026-07-24 14:19:44.077972+00
2898	1085	212-11AK-R	legacy	2026-07-24 14:19:44.077972+00
2899	1085	FAROL TOYOTA HILUX REVO	legacy	2026-07-24 14:19:44.077972+00
2900	1085	212-11AK	legacy	2026-07-24 14:19:44.077972+00
2901	1086	215-1543	legacy	2026-07-24 14:19:44.077972+00
2902	1086	215-1543-L	legacy	2026-07-24 14:19:44.077972+00
2903	1086	Guiñador Nissan patrol 87	legacy	2026-07-24 14:19:44.077972+00
2904	1087	215-1543	legacy	2026-07-24 14:19:44.077972+00
2905	1087	215-1543-R	legacy	2026-07-24 14:19:44.077972+00
2906	1087	Guiñador Nissan patrol 87	legacy	2026-07-24 14:19:44.077972+00
2907	1088	333-1608	legacy	2026-07-24 14:19:44.077972+00
2908	1088	GUIÑADOR CHEVROLET COLORADO	legacy	2026-07-24 14:19:44.077972+00
2909	1088	333-1608-L	legacy	2026-07-24 14:19:44.077972+00
2910	1089	333-1608	legacy	2026-07-24 14:19:44.077972+00
2911	1089	333-1608-R	legacy	2026-07-24 14:19:44.077972+00
2912	1089	GUIÑADOR CHEVROLET COLORADO	legacy	2026-07-24 14:19:44.077972+00
2913	1090	STOP HIACE LOBO TUNNIG	legacy	2026-07-24 14:19:44.077972+00
2914	1090	212-19F9-L	legacy	2026-07-24 14:19:44.077972+00
2915	1090	212-19F9	legacy	2026-07-24 14:19:44.077972+00
2916	1091	STOP HIACE LOBO TUNNIG	legacy	2026-07-24 14:19:44.077972+00
2917	1091	212-19F9-R	legacy	2026-07-24 14:19:44.077972+00
2918	1091	212-19F9	legacy	2026-07-24 14:19:44.077972+00
2919	1092	312-1549	legacy	2026-07-24 14:19:44.077972+00
2920	1092	312-1549-L	legacy	2026-07-24 14:19:44.077972+00
2921	1092	GUIÑADOR CELICA TOYOTA	legacy	2026-07-24 14:19:44.077972+00
2922	1093	312-1549	legacy	2026-07-24 14:19:44.077972+00
2923	1093	GUIÑADOR CELICA TOYOTA	legacy	2026-07-24 14:19:44.077972+00
2924	1093	312-1549-R	legacy	2026-07-24 14:19:44.077972+00
2925	1094	333-1636-L	legacy	2026-07-24 14:19:44.077972+00
2926	1094	333-1636	legacy	2026-07-24 14:19:44.077972+00
2927	1094	Guiñador jeep renegade	legacy	2026-07-24 14:19:44.077972+00
2928	1095	5283	legacy	2026-07-24 14:19:44.077972+00
2929	1095	RETROVISOR DE CAPO TOYOTA HILUX SURF	legacy	2026-07-24 14:19:44.077972+00
2930	1095	5283-L	legacy	2026-07-24 14:19:44.077972+00
2931	1096	314-1146-L	legacy	2026-07-24 14:19:44.077972+00
2932	1096	314-1146	legacy	2026-07-24 14:19:44.077972+00
2933	1097	212-1989	legacy	2026-07-24 14:19:44.077972+00
2934	1097	Stop corolla 90	legacy	2026-07-24 14:19:44.077972+00
2935	1097	212-1989-L	legacy	2026-07-24 14:19:44.077972+00
2936	1098	212-1989	legacy	2026-07-24 14:19:44.077972+00
2937	1098	Stop corolla 90	legacy	2026-07-24 14:19:44.077972+00
2938	1098	212-1989-R	legacy	2026-07-24 14:19:44.077972+00
2939	1099	Farol Toyota ipsum	legacy	2026-07-24 14:19:44.077972+00
2940	1099	44-3-R	legacy	2026-07-24 14:19:44.077972+00
2941	1099	44-3	legacy	2026-07-24 14:19:44.077972+00
2942	1100	21-16-R	legacy	2026-07-24 14:19:44.077972+00
2943	1100	FAROL TOYORA. ALDINA ORIGINAL	legacy	2026-07-24 14:19:44.077972+00
2944	1100	21-16	legacy	2026-07-24 14:19:44.077972+00
2945	1101	STOP RENAULT KIWID	legacy	2026-07-24 14:19:44.077972+00
2946	1101	551-19AJ	legacy	2026-07-24 14:19:44.077972+00
2947	1101	551-19AJ-R	legacy	2026-07-24 14:19:44.077972+00
2948	1102	215-1562	legacy	2026-07-24 14:19:44.077972+00
2949	1102	215-1562-L	legacy	2026-07-24 14:19:44.077972+00
2950	1102	MEDIA LUZ NISSAN SUNNY 90	legacy	2026-07-24 14:19:44.077972+00
2951	1103	Farol lancer 89	legacy	2026-07-24 14:19:44.077972+00
2952	1103	214-1112-L	legacy	2026-07-24 14:19:44.077972+00
2953	1103	214-1112	legacy	2026-07-24 14:19:44.077972+00
2954	1104	215-1614-L	legacy	2026-07-24 14:19:44.077972+00
2955	1104	Guiñador Nissan parachoques mini datsun	legacy	2026-07-24 14:19:44.077972+00
2956	1104	215-1614	legacy	2026-07-24 14:19:44.077972+00
2957	1105	215-1614-R	legacy	2026-07-24 14:19:44.077972+00
2958	1105	Guiñador Nissan parachoques mini datsun	legacy	2026-07-24 14:19:44.077972+00
2959	1105	215-1614	legacy	2026-07-24 14:19:44.077972+00
2960	1106	215-1562	legacy	2026-07-24 14:19:44.077972+00
2961	1106	MEDIA LUZ NISSAN SUNNY 90	legacy	2026-07-24 14:19:44.077972+00
2962	1106	215-1562-R	legacy	2026-07-24 14:19:44.077972+00
2963	1107	214-1531-R	legacy	2026-07-24 14:19:44.077972+00
2964	1107	214-1531	legacy	2026-07-24 14:19:44.077972+00
2965	1107	Media luz montero 92	legacy	2026-07-24 14:19:44.077972+00
2966	1108	331-1524	legacy	2026-07-24 14:19:44.077972+00
2967	1108	331-1524-L	legacy	2026-07-24 14:19:44.077972+00
2968	1108	Guiñador Ford Explorer 99	legacy	2026-07-24 14:19:44.077972+00
2969	1109	331-1524	legacy	2026-07-24 14:19:44.077972+00
2970	1109	Guiñador Ford Explorer 99	legacy	2026-07-24 14:19:44.077972+00
2971	1109	331-1524-R	legacy	2026-07-24 14:19:44.077972+00
2972	1110	MEDIA LUZ COROLLA 92 CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2973	1110	212-15D8-L	legacy	2026-07-24 14:19:44.077972+00
2974	1110	212-15D8	legacy	2026-07-24 14:19:44.077972+00
2975	1111	MEDIA LUZ COROLLA 92 CRISTALIZADO	legacy	2026-07-24 14:19:44.077972+00
2976	1111	212-15D8	legacy	2026-07-24 14:19:44.077972+00
2977	1111	212-15D8-R	legacy	2026-07-24 14:19:44.077972+00
2978	1112	MEDIA LUZ TOYOTA CALDINA	legacy	2026-07-24 14:19:44.077972+00
2979	1112	212-1580-L	legacy	2026-07-24 14:19:44.077972+00
2980	1112	212-1580	legacy	2026-07-24 14:19:44.077972+00
2981	1113	MEDIA LUZ TOYOTA CALDINA	legacy	2026-07-24 14:19:44.077972+00
2982	1113	212-1580	legacy	2026-07-24 14:19:44.077972+00
2983	1113	212-1580-R	legacy	2026-07-24 14:19:44.077972+00
2984	1114	218-1610	legacy	2026-07-24 14:19:44.077972+00
2985	1114	SUZUKI NEW VITARA ALÓGENO	legacy	2026-07-24 14:19:44.077972+00
2986	1114	218-1610-L	legacy	2026-07-24 14:19:44.077972+00
2987	1115	218-1610	legacy	2026-07-24 14:19:44.077972+00
2988	1115	218-1610-R	legacy	2026-07-24 14:19:44.077972+00
2989	1115	SUZUKI NEW VITARA ALÓGENO	legacy	2026-07-24 14:19:44.077972+00
2990	1116	Espejo COROLLA 92 NEGRO R/L Retrovisor MAMUT Unidad CARIB SPRINTER	legacy	2026-07-24 14:19:44.077972+00
2991	1116	222111	legacy	2026-07-24 14:19:44.077972+00
2992	1116	222111-L	legacy	2026-07-24 14:19:44.077972+00
2993	1117	222110	legacy	2026-07-24 14:19:44.077972+00
2994	1117	222110-R	legacy	2026-07-24 14:19:44.077972+00
2995	1118	44-26	legacy	2026-07-24 14:19:44.077972+00
2996	1118	44-26-L	legacy	2026-07-24 14:19:44.077972+00
2997	1118	Guiñador Toyota ipsum	legacy	2026-07-24 14:19:44.077972+00
2998	1119	44-26-R	legacy	2026-07-24 14:19:44.077972+00
2999	1119	44-26	legacy	2026-07-24 14:19:44.077972+00
3000	1119	Guiñador Toyota ipsum	legacy	2026-07-24 14:19:44.077972+00
\.


--
-- Data for Name: stock_movement; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stock_movement (movement_id, item_id, branch_id, qty_delta, condition, reason, note, occurred_at, created_by) FROM stdin;
1	1	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
2	2	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
3	3	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
4	4	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
5	5	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
6	6	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
7	7	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
8	8	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
9	9	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
10	10	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
11	11	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
12	12	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
13	13	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
14	14	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
15	15	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
16	16	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
17	17	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
18	17	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
19	18	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
20	19	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
21	20	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
22	20	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
23	21	2	10	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
24	21	3	5	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
25	22	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
26	22	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
27	22	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
28	23	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
29	24	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
30	24	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
31	25	3	44	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
32	26	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
33	27	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
34	28	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
35	29	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
36	29	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
37	30	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
38	31	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
39	32	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
40	32	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
41	33	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
42	33	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
43	34	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
44	34	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
45	35	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
46	35	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
47	35	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
48	36	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
49	37	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
50	37	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
51	38	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
52	39	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
53	39	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
54	40	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
55	40	3	20	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
56	41	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
57	41	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
58	42	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
59	43	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
60	43	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
61	44	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
62	44	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
63	45	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
64	45	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
65	46	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
66	47	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
67	48	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
68	49	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
69	50	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
70	50	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
71	51	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
72	52	2	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
73	52	3	10	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
74	53	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
75	54	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
76	54	3	14	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
77	55	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
78	56	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
79	57	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
80	58	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
81	58	3	9	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
82	59	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
83	59	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
84	60	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
85	61	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
86	61	3	14	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
87	62	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
88	62	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
89	63	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
90	64	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
91	65	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
92	66	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
93	67	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
94	68	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
95	69	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
96	70	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
97	71	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
98	72	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
99	73	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
100	74	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
101	75	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
102	76	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
103	77	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
104	78	3	26	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
105	79	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
106	80	3	11	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
107	81	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
108	82	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
109	83	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
110	84	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
111	85	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
112	86	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
113	87	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
114	88	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
115	89	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
116	90	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
117	91	3	25	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
118	92	1	38	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
119	92	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
120	93	3	45	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
121	94	3	23	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
122	95	3	10	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
123	96	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
124	97	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
125	98	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
126	99	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
127	100	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
128	101	3	13	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
129	102	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
130	103	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
131	104	1	6	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
132	104	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
133	105	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
134	105	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
135	106	1	12	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
136	106	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
137	107	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
138	108	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
139	109	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
140	111	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
141	112	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
142	113	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
143	114	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
144	115	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
145	116	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
146	117	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
147	118	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
148	119	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
149	120	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
150	121	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
151	122	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
152	123	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
153	124	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
154	125	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
155	125	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
156	126	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
157	127	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
158	128	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
159	129	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
160	129	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
161	130	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
162	131	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
163	133	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
164	133	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
165	134	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
166	135	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
167	136	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
168	137	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
169	138	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
170	139	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
171	140	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
172	141	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
173	142	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
174	143	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
175	144	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
176	145	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
177	146	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
178	147	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
179	148	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
180	148	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
181	149	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
182	149	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
183	150	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
184	151	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
185	152	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
186	153	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
187	154	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
188	155	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
189	155	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
190	156	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
191	157	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
192	158	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
193	159	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
194	160	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
195	161	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
196	161	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
197	162	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
198	163	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
199	164	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
200	165	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
201	166	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
202	167	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
203	168	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
204	168	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
205	169	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
206	169	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
207	170	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
208	171	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
209	172	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
210	173	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
211	174	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
212	175	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
213	175	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
214	176	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
215	177	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
216	178	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
217	179	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
218	180	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
219	180	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
220	181	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
221	182	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
222	183	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
223	184	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
224	185	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
225	186	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
226	187	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
227	188	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
228	188	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
229	189	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
230	190	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
231	190	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
232	190	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
233	191	1	7	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
234	191	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
235	191	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
236	192	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
237	193	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
238	194	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
239	194	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
240	194	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
241	195	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
242	195	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
243	196	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
244	197	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
245	198	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
246	199	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
247	200	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
248	201	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
249	202	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
250	202	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
251	203	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
252	203	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
253	204	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
254	204	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
255	205	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
256	205	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
257	205	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
258	206	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
259	208	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
260	209	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
261	210	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
262	211	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
263	212	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
264	213	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
265	213	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
266	214	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
267	214	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
268	215	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
269	215	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
270	216	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
271	217	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
272	218	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
273	219	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
274	220	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
275	220	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
276	221	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
277	222	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
278	223	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
279	224	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
280	225	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
281	225	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
282	226	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
283	227	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
284	227	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
285	228	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
286	229	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
287	230	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
288	231	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
289	232	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
290	233	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
291	234	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
292	235	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
293	236	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
294	236	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
295	237	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
296	238	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
297	239	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
298	240	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
299	241	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
300	242	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
301	243	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
302	244	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
303	244	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
304	245	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
305	245	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
306	245	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
307	246	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
308	246	3	5	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
309	247	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
310	247	2	6	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
311	248	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
312	248	2	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
313	248	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
314	249	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
315	249	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
316	250	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
317	250	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
318	251	1	14	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
319	251	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
320	252	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
321	253	1	14	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
322	254	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
323	255	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
324	256	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
325	257	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
326	258	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
327	259	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
328	260	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
329	261	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
330	262	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
331	263	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
332	263	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
333	264	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
334	265	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
335	266	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
336	267	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
337	268	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
338	269	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
339	270	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
340	271	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
341	272	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
342	273	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
343	275	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
344	276	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
345	277	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
346	278	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
347	279	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
348	280	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
349	281	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
350	282	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
351	283	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
352	283	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
353	284	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
354	285	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
355	285	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
356	286	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
357	287	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
358	288	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
359	289	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
360	290	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
361	291	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
362	292	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
363	293	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
364	294	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
365	295	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
366	296	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
367	297	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
368	298	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
369	299	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
370	300	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
371	301	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
372	302	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
373	303	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
374	304	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
375	304	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
376	304	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
377	305	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
378	305	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
379	306	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
380	307	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
381	308	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
382	309	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
383	310	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
384	311	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
385	312	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
386	313	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
387	313	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
388	314	3	5	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
389	315	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
390	315	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
391	316	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
392	317	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
393	318	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
394	319	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
395	320	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
396	321	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
397	322	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
398	323	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
399	324	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
400	325	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
401	326	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
402	327	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
403	328	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
404	329	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
405	330	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
406	331	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
407	332	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
408	333	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
409	334	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
410	335	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
411	336	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
412	338	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
413	339	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
414	340	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
415	341	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
416	342	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
417	343	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
418	344	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
419	345	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
420	346	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
421	347	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
422	348	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
423	348	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
424	349	3	5	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
425	350	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
426	351	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
427	352	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
428	353	3	5	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
429	354	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
430	355	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
431	356	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
432	356	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
433	357	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
434	357	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
435	358	3	60	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
436	359	3	20	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
437	360	3	60	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
438	361	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
439	362	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
440	363	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
441	364	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
442	365	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
443	365	3	22	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
444	366	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
445	366	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
446	367	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
447	367	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
448	368	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
449	369	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
450	370	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
451	371	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
452	372	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
453	373	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
454	374	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
455	375	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
456	376	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
457	377	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
458	377	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
459	378	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
460	379	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
461	380	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
462	381	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
463	384	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
464	384	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
465	385	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
466	386	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
467	387	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
468	388	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
469	389	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
470	390	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
471	391	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
472	392	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
473	393	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
474	394	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
475	395	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
476	396	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
477	396	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
478	397	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
479	397	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
480	398	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
481	399	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
482	400	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
483	400	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
484	401	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
485	401	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
486	402	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
487	402	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
488	403	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
489	403	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
490	404	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
491	405	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
492	406	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
493	407	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
494	407	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
495	408	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
496	408	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
497	409	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
498	410	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
499	411	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
500	412	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
501	413	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
502	414	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
503	415	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
504	416	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
505	417	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
506	418	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
507	419	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
508	419	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
509	420	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
510	420	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
511	420	3	8	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
512	421	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
513	422	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
514	423	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
515	423	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
516	423	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
517	424	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
518	424	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
519	425	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
520	425	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
521	426	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
522	427	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
523	428	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
524	429	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
525	430	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
526	431	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
527	432	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
528	433	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
529	434	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
530	435	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
531	436	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
532	436	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
533	437	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
534	437	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
535	438	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
536	439	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
537	440	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
538	441	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
539	442	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
540	443	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
541	444	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
542	445	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
543	446	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
544	447	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
545	448	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
546	448	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
547	449	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
548	449	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
549	450	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
550	451	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
551	452	1	6	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
552	452	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
553	453	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
554	453	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
555	454	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
556	455	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
557	456	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
558	457	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
559	458	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
560	459	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
561	460	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
562	461	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
563	462	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
564	462	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
565	463	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
566	464	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
567	465	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
568	466	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
569	467	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
570	468	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
571	469	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
572	470	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
573	472	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
574	473	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
575	474	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
576	474	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
577	474	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
578	475	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
579	476	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
580	477	3	17	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
581	478	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
582	479	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
583	480	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
584	481	3	30	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
585	482	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
586	483	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
587	484	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
588	485	3	24	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
589	486	3	30	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
590	487	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
591	488	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
592	489	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
593	490	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
594	490	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
595	491	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
596	492	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
597	493	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
598	493	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
599	494	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
600	495	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
601	496	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
602	497	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
603	498	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
604	499	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
605	500	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
606	500	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
607	501	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
608	502	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
609	503	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
610	504	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
611	505	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
612	506	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
613	507	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
614	508	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
615	509	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
616	510	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
617	511	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
618	512	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
619	513	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
620	514	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
621	515	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
622	516	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
623	517	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
624	518	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
625	519	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
626	520	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
627	521	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
628	522	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
629	523	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
630	523	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
631	524	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
632	525	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
633	526	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
634	527	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
635	528	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
636	529	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
637	530	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
638	531	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
639	532	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
640	533	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
641	534	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
642	535	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
643	536	3	8	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
644	537	3	15	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
645	538	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
646	539	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
647	540	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
648	541	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
649	541	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
650	542	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
651	543	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
652	544	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
653	544	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
654	545	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
655	546	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
656	547	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
657	548	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
658	549	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
659	550	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
660	551	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
661	552	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
662	553	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
663	554	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
664	555	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
665	556	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
666	557	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
667	558	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
668	559	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
669	559	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
670	560	1	7	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
671	560	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
672	561	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
673	562	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
674	563	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
675	564	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
676	565	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
677	566	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
678	567	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
679	568	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
680	569	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
681	570	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
682	571	3	2	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
683	572	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
684	572	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
685	573	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
686	574	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
687	575	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
688	576	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
689	576	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
690	577	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
691	578	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
692	579	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
693	580	2	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
694	580	3	10	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
695	581	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
696	581	3	12	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
697	582	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
698	582	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
699	582	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
700	583	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
701	584	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
702	585	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
703	585	2	10	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
704	586	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
705	587	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
706	588	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
707	589	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
708	589	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
709	590	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
710	590	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
711	591	2	6	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
712	592	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
713	593	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
714	593	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
715	594	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
716	594	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
717	595	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
718	596	3	18	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
719	597	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
720	598	1	12	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
721	599	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
722	599	3	17	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
723	600	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
724	601	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
725	602	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
726	602	3	12	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
727	603	3	11	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
728	604	3	16	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
729	605	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
730	605	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
731	606	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
732	607	2	6	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
733	607	3	9	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
734	608	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
735	609	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
736	609	3	30	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
737	610	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
738	610	3	24	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
739	611	3	10	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
740	612	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
741	613	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
742	614	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
743	614	2	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
744	615	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
745	616	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
746	617	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
747	618	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
748	619	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
749	620	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
750	621	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
751	622	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
752	623	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
753	624	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
754	625	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
755	626	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
756	627	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
757	628	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
758	629	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
759	630	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
760	631	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
761	632	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
762	633	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
763	633	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
764	634	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
765	634	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
766	635	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
767	636	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
768	637	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
769	638	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
770	639	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
771	640	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
772	641	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
773	642	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
774	643	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
775	644	3	7	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
776	645	3	9	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
777	646	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
778	646	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
779	647	3	21	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
780	648	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
781	649	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
782	650	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
783	651	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
784	652	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
785	653	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
786	654	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
787	655	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
788	656	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
789	657	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
790	658	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
791	659	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
792	660	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
793	661	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
794	662	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
795	663	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
796	664	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
797	665	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
798	666	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
799	667	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
800	668	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
801	668	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
802	669	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
803	670	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
804	671	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
805	672	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
806	673	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
807	674	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
808	675	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
809	676	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
810	676	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
811	677	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
812	677	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
813	678	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
814	678	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
815	679	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
816	679	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
817	680	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
818	680	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
819	681	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
820	681	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
821	682	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
822	683	3	9	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
823	684	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
824	685	1	6	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
825	685	3	8	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
826	686	1	7	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
827	686	3	3	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
828	687	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
829	688	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
830	689	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
831	690	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
832	691	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
833	692	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
834	693	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
835	693	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
836	694	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
837	694	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
838	695	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
839	695	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
840	696	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
841	697	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
842	698	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
843	699	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
844	700	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
845	701	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
846	702	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
847	703	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
848	704	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
849	704	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
850	705	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
851	705	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
852	706	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
853	707	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
854	708	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
855	708	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
856	709	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
857	709	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
858	710	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
859	710	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
860	711	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
861	712	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
862	713	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
863	714	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
864	714	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
865	715	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
866	716	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
867	716	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
868	717	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
869	718	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
870	719	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
871	719	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
872	720	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
873	720	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
874	721	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
875	722	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
876	723	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
877	724	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
878	725	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
879	726	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
880	727	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
881	728	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
882	729	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
883	730	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
884	731	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
885	732	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
886	733	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
887	734	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
888	734	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
889	735	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
890	735	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
891	736	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
892	737	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
893	738	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
894	739	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
895	741	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
896	741	3	2	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
897	742	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
898	742	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
899	743	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
900	744	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
901	745	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
902	746	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
903	747	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
904	748	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
905	749	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
906	750	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
907	751	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
908	752	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
909	753	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
910	754	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
911	754	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
912	755	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
913	756	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
914	756	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
915	757	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
916	758	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
917	759	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
918	760	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
919	761	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
920	762	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
921	763	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
922	764	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
923	764	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
924	765	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
925	766	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
926	767	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
927	768	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
928	769	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
929	770	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
930	771	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
931	772	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
932	772	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
933	773	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
934	774	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
935	775	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
936	776	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
937	777	1	7	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
938	778	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
939	778	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
940	779	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
941	780	1	3	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
942	781	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
943	782	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
944	783	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
945	784	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
946	785	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
947	786	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
948	787	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
949	788	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
950	788	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
951	789	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
952	790	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
953	791	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
954	792	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
955	793	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
956	794	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
957	794	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
958	795	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
959	796	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
960	796	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
961	797	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
962	797	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
963	798	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
964	799	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
965	800	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
966	800	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
967	801	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
968	801	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
969	802	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
970	803	1	9	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
971	803	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
972	804	1	6	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
973	804	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
974	805	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
975	806	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
976	806	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
977	807	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
978	807	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
979	808	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
980	809	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
981	810	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
982	811	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
983	812	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
984	812	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
985	812	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
986	813	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
987	813	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
988	813	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
989	814	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
990	814	3	2	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
991	815	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
992	815	3	1	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
993	816	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
994	816	3	6	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
995	816	3	4	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
996	817	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
997	817	3	10	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
998	817	3	3	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
999	818	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1000	820	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1001	821	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1002	822	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1003	822	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1004	823	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1005	824	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1006	825	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1007	826	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1008	827	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1009	828	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1010	829	1	28	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1011	829	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1012	830	1	27	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1013	830	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1014	830	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1015	831	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1016	832	1	5	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1017	832	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1018	833	1	8	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1019	834	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1020	836	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1021	837	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1022	838	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1023	839	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1024	840	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1025	841	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1026	842	2	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1027	843	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1028	844	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1029	844	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1030	844	3	2	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
1031	845	3	5	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1032	845	3	14	defective	opening	marked Defectuoso	2023-01-31 04:00:00+00	migration
1033	846	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1034	847	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1035	848	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1036	849	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1037	850	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1038	851	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1039	851	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1040	852	3	5	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1041	853	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1042	854	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1043	855	1	2	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1044	855	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1045	855	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1046	856	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1047	857	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1048	858	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1049	859	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1050	860	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1051	861	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1052	862	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1053	863	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1054	864	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1055	865	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1056	866	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1057	868	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1058	869	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1059	870	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1060	870	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1061	871	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1062	871	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1063	872	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1064	873	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1065	874	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1066	875	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1067	875	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1068	876	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1069	877	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1070	878	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1071	879	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1072	879	3	4	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1073	880	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1074	881	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1075	882	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1076	883	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1077	884	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1078	885	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1079	886	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1080	887	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1081	888	3	1	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1082	889	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1083	890	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1084	891	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1085	892	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1086	892	3	2	good	opening	location unknown in legacy file	2023-01-31 04:00:00+00	migration
1087	893	1	4	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1088	893	2	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
1089	894	1	1	good	opening	opening count 2023-01	2023-01-31 04:00:00+00	migration
\.


--
-- Data for Name: stocktake; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stocktake (stocktake_id, branch_id, label, status, started_at, closed_at, created_by) FROM stdin;
\.


--
-- Data for Name: stocktake_line; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stocktake_line (stocktake_id, item_id, condition, counted_qty, expected_qty, note, counted_at, counted_by) FROM stdin;
\.


--
-- Name: branch_branch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.branch_branch_id_seq', 3, true);


--
-- Name: category_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.category_category_id_seq', 74, true);


--
-- Name: item_alias_alias_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.item_alias_alias_id_seq', 3027, true);


--
-- Name: item_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.item_item_id_seq', 1119, true);


--
-- Name: stock_movement_movement_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.stock_movement_movement_id_seq', 1089, true);


--
-- Name: stocktake_stocktake_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.stocktake_stocktake_id_seq', 1, false);


--
-- Name: branch branch_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_code_key UNIQUE (code);


--
-- Name: branch branch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch
    ADD CONSTRAINT branch_pkey PRIMARY KEY (branch_id);


--
-- Name: category category_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.category
    ADD CONSTRAINT category_name_key UNIQUE (name);


--
-- Name: category category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.category
    ADD CONSTRAINT category_pkey PRIMARY KEY (category_id);


--
-- Name: item_alias item_alias_item_id_alias_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_alias
    ADD CONSTRAINT item_alias_item_id_alias_key UNIQUE (item_id, alias);


--
-- Name: item_alias item_alias_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_alias
    ADD CONSTRAINT item_alias_pkey PRIMARY KEY (alias_id);


--
-- Name: item item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item
    ADD CONSTRAINT item_pkey PRIMARY KEY (item_id);


--
-- Name: item item_sku_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item
    ADD CONSTRAINT item_sku_key UNIQUE (sku);


--
-- Name: stock_movement stock_movement_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movement
    ADD CONSTRAINT stock_movement_pkey PRIMARY KEY (movement_id);


--
-- Name: stocktake_line stocktake_line_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocktake_line
    ADD CONSTRAINT stocktake_line_pkey PRIMARY KEY (stocktake_id, item_id, condition);


--
-- Name: stocktake stocktake_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocktake
    ADD CONSTRAINT stocktake_pkey PRIMARY KEY (stocktake_id);


--
-- Name: alias_norm_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX alias_norm_trgm ON public.item_alias USING gin (alias_norm public.gin_trgm_ops);


--
-- Name: item_code_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX item_code_trgm ON public.item USING gin (public.norm_text(COALESCE(part_code, ''::text)) public.gin_trgm_ops);


--
-- Name: item_desc_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX item_desc_trgm ON public.item USING gin (public.norm_text(description) public.gin_trgm_ops);


--
-- Name: stock_movement_item_branch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stock_movement_item_branch ON public.stock_movement USING btree (item_id, branch_id);


--
-- Name: stock_movement_occurred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stock_movement_occurred ON public.stock_movement USING btree (occurred_at DESC);


--
-- Name: stocktake_one_open_per_branch; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stocktake_one_open_per_branch ON public.stocktake USING btree (branch_id) WHERE (status = 'open'::public.stocktake_status);


--
-- Name: item_alias item_alias_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_alias
    ADD CONSTRAINT item_alias_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.item(item_id) ON DELETE CASCADE;


--
-- Name: item item_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item
    ADD CONSTRAINT item_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.category(category_id);


--
-- Name: stock_movement stock_movement_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movement
    ADD CONSTRAINT stock_movement_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- Name: stock_movement stock_movement_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movement
    ADD CONSTRAINT stock_movement_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.item(item_id);


--
-- Name: stocktake stocktake_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocktake
    ADD CONSTRAINT stocktake_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branch(branch_id);


--
-- Name: stocktake_line stocktake_line_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocktake_line
    ADD CONSTRAINT stocktake_line_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.item(item_id);


--
-- Name: stocktake_line stocktake_line_stocktake_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stocktake_line
    ADD CONSTRAINT stocktake_line_stocktake_id_fkey FOREIGN KEY (stocktake_id) REFERENCES public.stocktake(stocktake_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict vipyhzlvPprbVNaymsgUsruAWBepdGbdkCK6kWo9zTzUY8mXv5XnXOOTMOIdcfo

