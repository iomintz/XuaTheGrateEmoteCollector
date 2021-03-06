-- Emote Collector collects emotes from other servers for use by people without Nitro
-- Copyright © 2019 lambda#0987
--
-- Emote Collector is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
--
-- Emote Collector is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with Emote Collector. If not, see <https://www.gnu.org/licenses/>.

--- CACHE SYNCHRONIZATION

-- :macro add_guild()
-- params: guild_id
INSERT INTO _guilds (id)
VALUES ($1)
ON CONFLICT DO NOTHING
-- :endmacro

-- :macro delete_guild()
-- params: guild_id
DELETE FROM _guilds
WHERE id = $1
-- :endmacro

-- :macro delete_all_moderators()
DELETE FROM moderators
-- :endmacro

-- :macro add_moderator()
-- params: moderator_id
INSERT INTO moderators (id)
VALUES ($1)
ON CONFLICT (id) DO NOTHING
-- :endmacro

-- :macro delete_moderator()
-- params: moderator_id
DELETE FROM moderators
WHERE id = $1
-- :endmacro

--- INFORMATIONAL

-- :macro free_guild(animated)
SELECT id
FROM guilds
WHERE {{ 'animated' if animated else 'static' }}_usage < 50
ORDER BY last_creation
LIMIT 1
-- :endmacro

-- :macro count()
SELECT
	COUNT(*) FILTER (WHERE NOT animated) AS static,
	COUNT(*) FILTER (WHERE animated) AS animated,
	COUNT(*) FILTER (WHERE nsfw != 'SFW') AS nsfw,
	COUNT(*) AS total
FROM emotes
-- :endmacro

-- :macro get_emote()
-- params: name
SELECT *
FROM emotes
WHERE LOWER(name) = LOWER($1)
-- :endmacro

-- :macro get_emote_usage()
-- params: id, cutoff_time
SELECT COUNT(*)
FROM emote_usage_history
WHERE id = $1
  AND time > $2
-- :endmacro

-- :macro get_reply_message()
-- params: invoking_message_id
SELECT type, reply_message
FROM replies
WHERE invoking_message = $1
-- :endmacro

--- ITERATORS

-- :macro all_emotes_keyset(sort_order, filter_author=False)
SELECT *
FROM emotes
WHERE nsfw = ANY ($1)
-- :set argc = 2
-- :if sort_order is defined
	AND LOWER(name) {{ '>' if sort_order == 'ASC' else '<' }} LOWER(${{ argc }})
	-- :set argc = argc + 1
-- :endif
-- :if filter_author
	AND author = ${{ argc }}
	-- :set argc = argc + 1
-- :endif
ORDER BY LOWER(name) {{ sort_order }} LIMIT 100
-- :endmacro

-- :set emote_usage_history_prelude
SELECT e.*, COUNT(euh.id) AS usage
FROM
	emotes AS e
	LEFT JOIN emote_usage_history AS euh
		ON euh.id = e.id
		AND euh.time > $1
-- :endset

-- :macro popular_emotes(filter_author=False)
-- params: cutoff_time, limit, allowed_nsfw_types, author_id (optional)
{{ emote_usage_history_prelude }}
WHERE
	nsfw = ANY ($3)
	{% if filter_author %}AND author = $4{% endif %}
GROUP BY e.id
ORDER BY usage DESC, LOWER(e.name)
LIMIT $2
-- :endmacro

-- :macro search()
-- params: query, allowed_nsfw_types
SELECT *
FROM emotes
WHERE name % $1
AND nsfw = ANY ($2)
ORDER BY similarity(name, $1) DESC, LOWER(name)
LIMIT 100
-- :endmacro

-- :macro decayable_emotes()
-- params: cutoff_time, usage_threshold
{{ emote_usage_history_prelude }}
WHERE
	created < $1
	AND NOT preserve
GROUP BY e.id
HAVING COUNT(euh.id) < $2
-- :endmacro

--- ACTIONS

-- :macro create_emote()
-- params: name, id, author, animated, guild
INSERT INTO emotes (name, id, author, animated, guild)
VALUES ($1, $2, $3, $4, $5)
RETURNING *
-- :endmacro

-- :macro remove_emote()
-- params: id
DELETE FROM emotes
WHERE id = $1
-- :endmacro

-- :macro rename_emote()
-- params: id, new_name
UPDATE emotes
SET name = $2
WHERE id = $1
RETURNING *
-- :endmacro

-- :macro set_emote_creation()
-- params: name, time
UPDATE EMOTES
SET created = $2
WHERE LOWER(name) = LOWER($1)
-- :endmacro

-- :macro set_emote_description()
-- params: id, description
UPDATE emotes
SET description = $2
WHERE id = $1
RETURNING *
-- :endmacro

-- :macro set_emote_preservation()
-- params: name, should_preserve
UPDATE emotes
SET preserve = $2
WHERE LOWER(name) = LOWER($1)
RETURNING *
-- :endmacro

-- :macro set_emote_nsfw()
-- params: id, new_status
UPDATE emotes
SET nsfw = $2
WHERE id = $1
RETURNING *
-- :endmacro

-- :macro log_emote_use()
-- params: id
INSERT INTO emote_usage_history (id)
VALUES ($1)
-- :endmacro

-- :macro add_reply_message()
-- params: invoking_message_id, reply_type, reply_message_id
INSERT INTO replies (invoking_message, type, reply_message)
VALUES ($1, $2, $3)
-- :endmacro

-- :macro delete_reply_by_invoking_message()
-- params: reply_message_id
DELETE FROM replies
WHERE invoking_message = $1
RETURNING reply_message
-- :endmacro

-- :macro delete_reply_by_reply_message()
-- params: reply_message_id
DELETE FROM replies
WHERE reply_message = $1
-- :endmacro

--- USER / GUILD OPTIONS

-- :macro delete_all_user_state()
-- params: user_id
DELETE FROM user_opt
WHERE id = $1
-- :endmacro

-- :macro toggle_state(table)
-- params: id, default
INSERT INTO {{ table }} (id, state)
VALUES ($1, $2)
ON CONFLICT (id) DO UPDATE
	SET state = NOT {{ table }}.state
RETURNING state
-- :endmacro

-- :macro get_individual_state(table)
-- params: id
SELECT state
FROM {{ table }}
WHERE id = $1
-- :endmacro

-- :macro get_state()
-- params: guild_id, user_id
SELECT COALESCE(
	CASE WHEN (SELECT blacklist_reason FROM user_opt WHERE id = $2) IS NOT NULL THEN FALSE END,
	(SELECT state FROM user_opt  WHERE id = $2),
	(SELECT state FROM guild_opt WHERE id = $1),
	true -- not opted in in the guild or the user table, default behavior is ENABLED
)
-- :endmacro

--- BLACKLISTS

-- :macro get_blacklist(table_name)
-- params: id
SELECT blacklist_reason
FROM {{ table_name }}
WHERE id = $1
-- :endmacro

-- :macro set_blacklist(table_name)
-- params: id, reason
INSERT INTO {{ table_name }} (id, blacklist_reason)
VALUES ($1, $2)
ON CONFLICT (id) DO UPDATE
	SET blacklist_reason = EXCLUDED.blacklist_reason
-- :endmacro

-- :macro blacklisted_guilds()
SELECT id
FROM guild_opt
WHERE blacklist_reason IS NOT NULL
-- :endmacro
