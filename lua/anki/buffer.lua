local M = {}
local UTIL = require("anki.utils")

--TODO: add noteID

---@class TableAnki
---@field form table
---@field pos_first_field 1-indexed position of the first field

---Creates a table of lines according to given inputs
---@param fields table Table of field names
---@param deckname string | nil Name of the deck
---@param modelname string Name of the model (note type)
---@param context table | nil Table of tags and fields to prefill
---@param latex_support boolean If true insert lines for tex support inside a buffer
---@param noteId number | nil If true insert lines for tex support inside a buffer
---@return TableAnki
M.create = function(fields, deckname, modelname, context, latex_support, noteId)
    local b = {}

    local pos = {
        has_seen_first_field = false,
        pos = 1,
    }

    if latex_support then
        table.insert(b, [[\documentclass[11pt, a4paper]{article}]])
        table.insert(b, [[\usepackage{amsmath}]])
        table.insert(b, [[\usepackage{amssymb}]])
        table.insert(b, [[\begin{document}]])
        pos.pos = pos.pos + 4
    end


    if noteId then
        table.insert(b, "%%NOTEID " .. noteId)
        pos.pos = pos.pos + 1
    else
        table.insert(b, "%%MODELNAME " .. modelname)
        pos.pos = pos.pos + 1

        if deckname then
            table.insert(b, "%%DECKNAME " .. deckname)
            pos.pos = pos.pos + 1
        end
    end

    if context and context.tags then
        table.insert(b, "%%TAGS" .. " " .. context.tags)
    else
        table.insert(b, "%%TAGS")
    end
    pos.pos = pos.pos + 1

    for _, e in ipairs(fields) do
        if not pos.has_seen_first_field then
            pos.pos = pos.pos + 1
            pos.has_seen_first_field = true
        end

        local field = "%" .. e

        table.insert(b, field)
        if context and context.fields and context.fields[e] then
            local t = type(context.fields[e])

            if t == "string" then
                local split_by_n = vim.split(context.fields[e], "\n")
                for _, k in ipairs(split_by_n) do
                    table.insert(b, k)
                end
            elseif t == "table"  then
                for _, k in ipairs(context.fields[e]) do
                    table.insert(b, k)
                end
            end
        else
            table.insert(b, "")
        end
        table.insert(b, field)
    end

    if latex_support then
        table.insert(b, [[\end{document}]])
    end

    return {
        form = b,
        pos_first_field = pos.pos,
    }
end

convert_line_to_anki_format = function(line)
    -- Replace `` with <code></code>
    begin_match, end_match = string.find(line, '`.-`')
    while begin_match do
      line = line:sub(1, begin_match - 1) .. "<code>" .. line:sub(begin_match + 1, end_match - 1) .. "</code>" .. line:sub(end_match + 1, -1)
      begin_match, end_match = string.find(line, '`.-`')
    end

    -- Replace ![](img_path) with <img src="img_path">
    begin_match, end_match = string.find(line, '!%[%]%(.-%)')
    while begin_match do
      img_path = line:sub(begin_match + 4, end_match - 1)
      begin_username, end_username = string.find(img_path, "/")
      img_path = img_path:sub(begin_username, -1)
      img_name = string.match(img_path, ".-([^/]-[^/%.]+)$")

      line = line:sub(2, begin_match - 1) .. '<img src="' .. img_name .. '">' .. line:sub(end_match + 1, -1)
      -- Store image in Anki, so that it can be referenced later
      status, data = pcall(require("anki.api").storeMediaFile, {
          filename = img_name,
          path = img_path,
          deleteExisting = false,
      })

      begin_match, end_match = string.find(line, '!%[%]%(.-%)')
    end

    -- Replace $$ with <anki-mathjax></anki-mathjax>
    begin_match, end_match = string.find(line, '%$.-%$')
    while begin_match do
      line = line:sub(1, begin_match - 1) .. "<anki-mathjax>" .. line:sub(begin_match + 1, end_match - 1) .. "</anki-mathjax>" .. line:sub(end_match + 1, -1)
      begin_match, end_match = string.find(line, '%$.-%$')
    end

    return line
end

---Parses an input into a table with 'note' subtable which can be send AnkiConnect
---@return Form, table?
M.parse = function(input)
    local result = { cards = {} }

    local lines
    if type(input) == "string" then
        lines = vim.split(input, "\n", {})
    else
        lines = input
    end

    local is_inside_field = { is = false, name = "", content = {}, line_number = -1 }

    card = {}
    in_card = false
    source = ""

    for line_counter, line in ipairs(lines) do
        -- If first line, check for header (added to all cards as an extra)
        if line_counter == 1 then
            if string.len(line) > 3 and line:sub(1, 3) == [[###]] then
              source = line:sub(3, -1)
            end
        end

        -- Basic format, new card
        if string.len(line) > 5 and line:sub(1,5) == [[> **_]] then
            if in_card then
              table.insert(result.cards, card)
              card = {}
              in_card = false
            end
            line = line:sub(6, string.find(line, "_**", 6) - 1)
            line = convert_line_to_anki_format(line)

            card = {
                modelName = "Basic",
                fields = {
                  Front = line,
                  Back = "",
                  Source = source,
                }
            }
            in_card = true
            goto continue
        end

        if in_card then
          -- Basic format, continue card
          if string.len(line) > 0 then
            line = convert_line_to_anki_format(line)

            if string.len(card.fields.Back) > 0 then
              card.fields.Back = card.fields.Back .. line
            else
              card.fields.Back = line
            end
          -- Exited card
          else
            table.insert(result.cards, card)
            card = {}
            in_card = false
          end
          goto continue
        end

        -- Check for valid cloze format
        if string.len(line) > 2 and line:sub(1,2) == [[> ]] then
            line = line:sub(3, -1)
            line = convert_line_to_anki_format(line)

            -- Replace ** with {{c1::}}
            cloze_idx = 1
            begin_match, end_match = string.find(line, '%*%*.-%*%*')
            while begin_match do

              -- Split up the line for readability
              before_match = line:sub(1, begin_match - 1)
              cloze = "{{c" .. cloze_idx .. "::" .. line:sub(begin_match + 2, end_match - 2) .. "}}"
              after_match = line:sub(end_match + 1, -1)

              -- Replace the line with the formatted cloze
              line = before_match .. cloze .. after_match

              -- Find next occurrence of ** and increment cloze index
              begin_match, end_match = string.find(line, '%*%*.-%*%*')
              cloze_idx = cloze_idx + 1
            end
            card = {
                modelName = "Cloze",
                fields = {
                  Text = line
                }
            }
            table.insert(result.cards, card)
            card = {}
            goto continue
        end

        ::continue::
    end

    if in_card then
      table.insert(result.cards, card)
      card = {}
      in_card = false
    end

    return result
end

---@class Field
---@field value string
---@field order number

---@class AnkiNote
---@field modelName string
---@field noteId number
---@field tags table<string>
---@field fields table<Field>

---@param ankiNote AnkiNote
---@return {fields_names: table<string>, fields_values: table<string>, modelname: string, context: table, noteId: number, tags: string}
M.parse_form_from_anki = function(ankiNote)
    local fields_names = {}
    local field_values = {}

    for k, v in pairs(ankiNote.fields) do
        fields_names[v.order + 1] = k

        local f = string.gsub(v.value, "[\n\r]", "")
        local split = vim.fn.split(f, "<br>")

        if #split ~= 0 then
            field_values[k] = split
        else
            field_values[k] = { "" }
        end
    end

    return {
        fields_names = fields_names,
        fields_values = field_values,
        modelname = ankiNote.modelName,
        noteId = ankiNote.noteId,
        tags = vim.fn.join(ankiNote.tags, " "),
    }
end

M.concat_lines = function(lines)
    return table.concat(lines, "<br>\n")
end

M.transform = function(form, transformers)
    local t = require("anki.transformer")

    -- stylua: ignore
    local result = t.try_to_tranform_with(form, transformers)
    -- stylua: ignore
    result = t.try_to_tranform_with(result, require("anki.helpers").global_variable("transformers"))
    -- stylua: ignore
    result = t.try_to_tranform_with(result, require("anki.helpers").buffer_variable("transformers"))

    return result
end

M.all = function(cur_buf, transformers)
    -- Ignoring transformers functionality for now
    return M.parse(cur_buf)
end

return M
