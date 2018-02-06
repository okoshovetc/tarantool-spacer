local clock = require 'clock'
local fio = require 'fio'
local fun = require 'fun'
local log = require 'log'

local fileio = require 'spacer.fileio'
local inspect = require 'spacer.myinspect'
local space_migration = require 'spacer.migration'
local util = require 'spacer.util'
local transformations = require 'spacer.transformations'

local NULL = require 'msgpack'.NULL

local SCHEMA_KEY = '_spacer_ver'
local SPACER_MODELS_SPACE = '_spacer_models'


local function _init_fields_and_transform(self, space_name, format)
    local f, f_extra = space_migration.generate_field_info(format)
    self.F[space_name] = f
    self.F_FULL[space_name] = f_extra
    self.T[space_name] = {}
    self.T[space_name].dict = transformations.tuple2hash(f)
    self.T[space_name].tuple = transformations.hash2tuple(f)
    self.T[space_name].hash = self.T[space_name].dict  -- alias
end


local function _space(self, name, format, indexes, opts)
    assert(name ~= nil, "Space name cannot be null")
    assert(format ~= nil, "Space format cannot be null")
    assert(indexes ~= nil, "Space indexes cannot be null")
    self.__models__[name] = {
        type = 'raw',
        space_name = name,
        space_format = format,
        space_indexes = indexes,
        space_opts = opts,
    }
    _init_fields_and_transform(self, name, format)

    if self.automigrate then
        local m = self:_makemigration('automigration', true, true)
        local compiled_code, err, ok

        compiled_code, err = loadstring(m)
        if compiled_code == nil then
            error(string.format('Cannot automigrate due to error: %s', err))
            return
        end

        ok, err = self:_migrate_one_up(compiled_code)
        if not ok then
            error(string.format('Error while applying migration: %s', err))
        end
    end
end

local function space(self, space_decl)
    assert(space_decl ~= nil, 'Space declaration is missing')
    return self:_space(space_decl.name, space_decl.format, space_decl.indexes, space_decl.opts)
end


local function space_drop(self, name)
    assert(name ~= nil, "Space name cannot be null")
    assert(self.__models__[name] ~= nil, "Space is not defined")

    self.__models__[name] = nil
    self.F[name] = nil
    self.F_FULL[name] = nil
    self.T[name] = nil
end


---
--- _migrate_one_up function
---
local function _migrate_one_up(self, migration)
    setfenv(migration, _G)
    local funcs = migration()
    assert(funcs ~= nil, 'Migration file should return { up = function() ... end, down = function() ... end } table')
    assert(funcs.up ~= nil, 'up function is required')
    local ok, err = pcall(funcs.up)
    if not ok then
        return false, err
    end
    return true, nil
end

---
--- migrate_up function
---
local function migrate_up(self, _n)
    local n = tonumber(_n)
    if n == nil and _n ~= nil then
        error('n must be a number or nil')
    end

    local ver_t = box.space._schema:get({SCHEMA_KEY})
    local ver, name
    if ver_t ~= nil then
        ver = ver_t[2]
        name = ver_t[3]
    end

    local migrations = util.read_migrations(self.migrations_path, 'up', ver, n)

    if #migrations == 0 then
        if name == nil then
            name = 'nil'
        end
        log.info('No migrations to apply. Last migration: %s_%s', inspect(ver), name)
        return nil
    end

    for _, m in ipairs(migrations) do
        local ok, err = self:_migrate_one_up(m.migration)
        if not ok then
            log.error('Error running migration %s: %s', m.filename, err)
            return {
                version = m.ver,
                name = m.name,
                migration = m.filename,
                error = err
            }
        end

        box.space._schema:replace({SCHEMA_KEY, m.ver, m.name})
        log.info('Applied migration "%s"', m.filename)
    end

    return nil
end


---
--- _migrate_one_down function
---
local function _migrate_one_down(self, migration)
    setfenv(migration, _G)
    local funcs = migration()
    assert(funcs ~= nil, 'Migration file should return { up = function() ... end, down = function() ... end } table')
    assert(funcs.down ~= nil, 'down function is required')
    local ok, err = pcall(funcs.down)
    if not ok then
        return false, err
    end
    return true, nil
end

---
--- migrate_down function
---
local function migrate_down(self, _n)
    local n = tonumber(_n)
    if n == nil and _n ~= nil then
        error('n must be a number or nil')
    end

    if n == nil then
        n = 1
    end

    local ver_t = box.space._schema:get({SCHEMA_KEY})
    local ver, name
    if ver_t ~= nil then
        ver = ver_t[2]
        name = ver_t[3]
    end

    local migrations = util.read_migrations(self.migrations_path, 'down', ver, n + 1)

    if #migrations == 0 then
        if name == nil then
            name = 'nil'
        end
        log.info('No migrations to apply. Last migration: %s_%s', inspect(ver), name)
        return nil
    end

    for i, m in ipairs(migrations) do
        local ok, err = self:_migrate_one_down(m.migration)
        if not ok then
            log.error('Error running migration %s: %s', m.filename, err)
            return {
                version = m.ver,
                name = m.name,
                migration = m.filename,
                error = err
            }
        end

        local prev_migration = migrations[i + 1]
        if prev_migration == nil then
            box.space._schema:delete({SCHEMA_KEY})
        else
            box.space._schema:replace({SCHEMA_KEY, prev_migration.ver, prev_migration.name})
        end
        log.info('Rolled back migration "%s"', m.filename)
        n = n - 1
        if n == 0 then
            break
        end
    end

    return nil
end


---
--- makemigration function
---
local function _makemigration(self, name, autogenerate, nofile)
    assert(name ~= nil, 'Migration name is required')
    if autogenerate == nil then
        autogenerate = true
    end
    local date = clock.time()

    local requirements_body = ''
    local up_body = ''
    local down_body = ''
    if autogenerate then
        local migration = space_migration.spaces_migration(self, self.__models__)
        requirements_body = table.concat(
            fun.iter(migration.requirements):map(
                function(key, r)
                    return string.format("local %s = require '%s'", r.name, key)
                end):totable(),
            '\n')

        local tab = string.rep(' ', 8)
        up_body = util.tabulate_string(table.concat(migration.up, '\n'), tab)
        down_body = util.tabulate_string(table.concat(migration.down, '\n'), tab)
    end

    local migration_body = string.format([[--
-- Migration "%s"
-- Date: %d - %s
--
%s

return {
    up = function()
%s
    end,

    down = function()
%s
    end,
}
]], name, date, os.date('%x %X', date), requirements_body, up_body, down_body)

    if not nofile then
        local path = fio.pathjoin(self.migrations_path, string.format('%d_%s.lua', date, name))
        fileio.write_to_file(path, migration_body)
    end
    return migration_body
end
local function makemigration(self, ...) self:_makemigration(...) end

---
--- clear_schema function
---
local function clear_schema(self)
    box.space._schema:delete({SCHEMA_KEY})
    self.models_space:truncate()
end

---
--- get function
---
local function get(self, name, compile)
    return util.read_migration(self.migrations_path, name, compile)
end

---
--- list function
---
local function list(self, verbose)
    if verbose == nil then
        verbose = false
    end
    return util.list_migrations(self.migrations_path, verbose)
end


local function _init_models_space(self)
    local sp = box.schema.create_space(SPACER_MODELS_SPACE, {if_not_exists = true})
    sp:format({
        {name = 'name', type = 'string'},
    })
    sp:create_index('primary', {
        parts = {
            {1, 'string'}
        },
        if_not_exists = true
    })

    return sp
end

local M = rawget(_G, '__spacer__')
if M ~= nil then
    -- 2nd+ load
    local m
    local prune_models = {}
    for m, _ in pairs(M.F) do
        if box.space._vspace.index.name:get({m}) == nil then
            table.insert(prune_models, m)
        end
    end

    M.__models__ = {}  -- clean all loaded models
    for _, m in ipairs(prune_models) do
        M.F[m] = nil
        M.F_FULL[m] = nil
        M.T[m] = nil
    end

    -- initialize current spaces fields and transformations
    for _, sp in box.space._vspace:pairs() do
        _init_fields_and_transform(M, sp[3], sp[7])
    end
else
    -- 1st load
    M = setmetatable({
        migrations_path = NULL,
        automigrate = NULL,
        keep_obsolete_spaces = NULL,
        keep_obsolete_indexes = NULL,
        down_migration_fail_on_impossible = NULL,
        models_space = NULL,
        __models__ = {},
        F = {},
        F_FULL = {},
        T = {},
    },{
        __call = function(self, user_opts)
            local valid_options = {
                migrations = {
                    required = true,
                    self_name = 'migrations_path'
                },
                global_ft = {
                    required = false,
                    default = true,
                },
                automigrate = {
                    required = false,
                    default = false,
                },
                keep_obsolete_spaces = {
                    required = false,
                    default = false,
                },
                keep_obsolete_indexes = {
                    required = false,
                    default = false,
                },
                down_migration_fail_on_impossible = {
                    required = false,
                    default = true,
                },
            }

            local opts = {}
            local invalid_options = {}
            -- check user provided options
            for key, value in pairs(user_opts) do
                local opt_info = valid_options[key]
                if opt_info == nil then
                    table.insert(invalid_options, key)
                else
                    if opt_info.required and value == nil then
                        error(string.format('Option "%s" is required', key))
                    elseif value == nil then
                        opts[key] = opt_info.default
                    else
                        opts[key] = value
                    end
                end
            end

            if #invalid_options > 0 then
                error(string.format('Unknown options provided: [%s]', table.concat(invalid_options, ', ')))
            end

            -- check that user provided all required options
            for valid_key, opt_info in pairs(valid_options) do
                local value = user_opts[valid_key]
                if opt_info.required and value == nil then
                    error(string.format('Option "%s" is required', valid_key))
                elseif user_opts[valid_key] == nil then
                    opts[valid_key] = opt_info.default
                else
                    opts[valid_key] = value
                end
            end

            if not fileio.exists(opts.migrations) then
                if not fio.mkdir(opts.migrations) then
                    local e = errno()
                    error(string.format("Couldn't create migrations dir '%s': %d/%s", opts.migrations, e, errno.strerror(e)))
                end
            end

            for valid_key, opt_info in pairs(valid_options) do
                if opt_info.self_name == nil then
                    opt_info.self_name = valid_key
                end

                self[opt_info.self_name] = opts[valid_key]
            end

            -- initialize current spaces fields and transformations
            for _, sp in box.space._vspace:pairs() do
                _init_fields_and_transform(self, sp[3], sp[7])
            end

            if opts.global_ft then
                rawset(_G, 'F', self.F)
                rawset(_G, 'F_FULL', self.F_FULL)
                rawset(_G, 'T', self.T)
            end

            self.models_space = _init_models_space(self)

            return self
        end,
        __index = {
            _space = _space,
            _migrate_one_up = _migrate_one_up,
            _migrate_one_down = _migrate_one_down,
            _makemigration = _makemigration,

            space = space,
            space_drop = space_drop,
            migrate_up = migrate_up,
            migrate_down = migrate_down,
            makemigration = makemigration,
            clear_schema = clear_schema,
            get = get,
            list = list,
        }
    })
    rawset(_G, '__spacer__', M)
end

return M
