-- MiaEvents — перехват событий Palworld (одиночная/локальная игра).
-- Пишет и в UE4SS.log (через print), и в свой events.log рядом с модом.
--
-- ВЕРСИЯ 2026-07-23 (финальная): смерть/убийство берём из ЖИВЫХ хуков, которые
-- реально дёргаются в одиночной игре (DropItem_FromEnemyDeath, OnDeadPlayer_Server) —
-- проверено логом. Встроенный kill-feed игры (AddKillLog/AddDeathLog) в синглплеере
-- НЕ вызывается, поэтому его убрали. Поимка и уровень — по фактам из CXX-дампа
-- (targetHandle сферы, nowLevel как настоящий уровень). Умирающие объекты НЕ трогаем.

-- events.log кладём ПРЯМО в папку мода, рядом со скриптом — портативно, без хардкода.
local function mod_log_path()
    local src = debug.getinfo(1, "S").source        -- "@C:\...\Mods\MiaEvents\scripts\main.lua"
    src = src:gsub("^@", "")                         -- убрать ведущий '@'
    local dir = src:match("^(.*)[/\\][Ss]cripts[/\\][^/\\]*$")  -- папка мода без /scripts/main.lua
    if dir then return dir .. "/events.log" end
    return "MiaEvents_events.log"                     -- фолбэк: рабочая папка игры
end
local LOG_PATH = mod_log_path()

-- Ротация лога при старте игры: если разросся — уводим в events_prev.log и
-- начинаем с чистого. Одна прошлая копия всегда под рукой, файл не пухнет вечно.
local LOG_MAX_BYTES = 2 * 1024 * 1024              -- 2 МБ (~20 тыс. строк событий)
pcall(function()
    local f = io.open(LOG_PATH, "r")
    if not f then return end
    local size = f:seek("end")
    f:close()
    if size and size > LOG_MAX_BYTES then
        local prev = LOG_PATH:gsub("events%.log$", "events_prev.log")
        os.remove(prev)                            -- на Windows rename поверх не работает
        os.rename(LOG_PATH, prev)
    end
end)

-- Технический лог: сырые латинские коды и диагностика ДЛЯ НАС (Олег+Мия).
-- Модель его НЕ читает — сюда льём то, чего в events.log быть не должно (сырые
-- коды, счётчики массивов), чтобы ловить «а что мы упускаем». Тот же путь, что у
-- events.log, но файл tech.log. Своя ротация — чтоб не пух вечно.
local TECH_PATH = LOG_PATH:gsub("events%.log$", "tech.log")
pcall(function()
    local f = io.open(TECH_PATH, "r")
    if not f then return end
    local size = f:seek("end")
    f:close()
    if size and size > LOG_MAX_BYTES then
        local prev = TECH_PATH:gsub("tech%.log$", "tech_prev.log")
        os.remove(prev)
        os.rename(TECH_PATH, prev)
    end
end)

-- Карта id -> имя активного навыка (приёма). Лежит рядом со скриптом (scripts/waza_names.lua),
-- сгенерена из CXX-дампа. Грузим один раз; если файла нет — просто покажем номера.
local WAZA_NAMES = {}
-- Словари русских имён: код пала -> русское имя, код предмета -> русское имя.
-- Лежат рядом со скриптом (pals_ru.lua / items_ru.lua). Чего в словаре нет —
-- показываем код как есть (безопасный откат). Файлы можно дополнять вручную.
local PALS_RU = {}
local ITEMS_RU = {}
local PASSIVES_RU = {}   -- код пассивки (FName) -> русское имя с уровнем
local WAZA_RU = {}       -- английское имя приёма -> русское имя
local REGIONS_RU = {}    -- код области (AreaName.Key) -> русское имя региона
pcall(function()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$")          -- папка scripts/
    if dir then
        local function load_map(name)
            local chunk = loadfile(dir .. "/" .. name)
            if chunk then
                local ok, t = pcall(chunk)
                if ok and type(t) == "table" then return t end
            end
            return {}
        end
        WAZA_NAMES  = load_map("waza_names.lua")
        PALS_RU     = load_map("pals_ru.lua")
        ITEMS_RU    = load_map("items_ru.lua")
        PASSIVES_RU = load_map("passives_ru.lua")
        WAZA_RU     = load_map("waza_ru.lua")
        REGIONS_RU  = load_map("regions_ru.lua")
    end
end)

-- Индекс словаря палов в нижнем регистре — вид приходит то из класса ("SheepBall"),
-- то из CharacterID ("Sheepball"), регистр разный. Строим один раз лениво.
local PALS_RU_LC = nil
local function pals_lc()
    if PALS_RU_LC == nil then
        PALS_RU_LC = {}
        for k, v in pairs(PALS_RU) do PALS_RU_LC[string.lower(k)] = v end
    end
    return PALS_RU_LC
end

-- Код пала -> русское имя. Срезаем префиксы боссов/рейдов/спортзалов перед поиском,
-- чтобы "BOSS_Hedgehog" находил "Hedgehog". Нет в словаре -> вернуть исходный код.
local function pal_ru(code)
    if type(code) ~= "string" or code == "" then return code end
    local bare = code:gsub("^BOSS_", ""):gsub("^RAID_", ""):gsub("^GYM_", ""):gsub("^PREDATOR_", "")
    return PALS_RU[bare] or PALS_RU[code]
        or pals_lc()[string.lower(bare)] or code
end

-- Флаг босса. У полевых альфа-боссов / рейд-боссов / боссов-спортзалов CharacterID
-- идёт с префиксом BOSS_/RAID_/GYM_. pal_ru его СРЕЗАЕТ (чтобы найти имя в словаре) —
-- и признак «это босс» терялся: поимка/убийство босса выглядели как обычный пал.
-- Возвращаем метку, читая СЫРОЙ код ДО среза. Пусто — если это рядовой пал.
local function boss_tag(code)
    if type(code) ~= "string" then return "" end
    if code:find("^PREDATOR_") then
        return "★БОСС-ПРЕДАТОР "
    end
    if code:find("^BOSS_") or code:find("^RAID_") or code:find("^GYM_") then
        return "★БОСС "
    end
    return ""
end

-- Индекс словаря предметов в нижнем регистре — id предметов приходят в разном
-- регистре ("bone" против "Wood"). Строим один раз лениво.
local ITEMS_RU_LC = nil
local function items_lc()
    if ITEMS_RU_LC == nil then
        ITEMS_RU_LC = {}
        for k, v in pairs(ITEMS_RU) do ITEMS_RU_LC[string.lower(k)] = v end
    end
    return ITEMS_RU_LC
end

-- Код предмета -> русское имя. Нет в словаре -> исходный код.
local function item_ru(code)
    if type(code) ~= "string" or code == "" then return code end
    return ITEMS_RU[code] or items_lc()[string.lower(code)] or code
end

local function stamp()
    local ok, t = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    if ok and t then return t else return "??:??:??" end
end

local function log(msg)
    local line = "[" .. stamp() .. "] " .. msg
    print("[MiaEvents] " .. line .. "\n")          -- в UE4SS.log и консоль
    pcall(function()                                -- в свой файл
        local f = io.open(LOG_PATH, "a")
        if f then f:write(line .. "\n"); f:close() end
    end)
end

-- Пишет ТОЛЬКО в tech.log (мимо модели) и в UE4SS.log. Для сырья и диагностики.
local function tech(msg)
    local line = "[" .. stamp() .. "] " .. msg
    print("[MiaEvents/tech] " .. line .. "\n")
    pcall(function()
        local f = io.open(TECH_PATH, "a")
        if f then f:write(line .. "\n"); f:close() end
    end)
end

-- Обёртка: ставит хук в pcall и пишет, поставился он или нет.
local function hook(path, cb)
    local ok = pcall(function() RegisterHook(path, cb) end)
    if ok then log("хук OK   -> " .. path)
    else       log("хук FAIL -> " .. path) end
    return ok
end

------------------------------------------------------------------------
-- БЕЗОПАСНОЕ ЧТЕНИЕ ИМЁН (вид пала / кто убил).
-- Правило после краша: НИКОГДА не нырять в поля объекта на событии смерти.
-- Читаем ТОЛЬКО пока объект жив (сфера при поимке, атакующий при уроне).
------------------------------------------------------------------------

-- развернуть RemoteUnrealParam из хука в само значение (объект/структуру/число/строку)
local function val(p)
    if p == nil then return nil end
    local v = nil
    pcall(function() v = p:get() end)
    if v ~= nil then return v end
    return p
end

-- Безопасно превратить FName/FString/число/строку в строку.
local function s(x)
    if x == nil then return nil end
    local out = nil
    pcall(function() out = x:ToString() end)   -- FName / FString
    if out ~= nil then return out end
    local t = type(x)
    if t == "string" or t == "number" or t == "boolean" then return tostring(x) end
    return tostring(x)
end

-- Строгая проверка «объект живой», ставить ПЕРЕД любым GetClass()/чтением поля.
-- Прежняя привычная строка `if o.IsValid and not o:IsValid() then return end`
-- ПРОПУСКАЛА всё, у чего метода IsValid нет вовсе (битый указатель, не-UObject),
-- и следом GetClass() валил игру целиком (краш 26.07 12:16, чтение адреса 0x10 —
-- это смещение ClassPrivate). pcall от нативного access violation НЕ спасает,
-- поэтому проверка обратная: нет IsValid → считаем объект мёртвым.
local function live_obj(o)
    if o == nil or type(o) ~= "userdata" then return false end
    if type(o.IsValid) ~= "function" then return false end
    local ok, alive = pcall(function() return o:IsValid() end)
    return ok and alive == true
end

-- Красивый вид: "BP_SheepBall_C" -> "SheepBall".
local function pretty(cls)
    if not cls then return nil end
    return (cls:gsub("^BP_", ""):gsub("_C$", ""))
end

-- Вид актёра по имени его класса. GetClass() отдаёт UClass (живёт вечно, не
-- разрушается вместе с актёром), поэтому читать безопасно даже у только что
-- павшего пала. Одно короткое обращение, всё в pcall + IsValid.
local function actor_species(actor)
    local sp = nil
    pcall(function()
        if actor == nil then return end
        if actor.IsValid and not actor:IsValid() then return end
        local cls = actor:GetClass()
        if cls then sp = pretty(cls:GetFName():ToString()) end
    end)
    return pal_ru(sp)
end

-- Найти среди параметров первое «существо» (вид пала/персонажа) — объект должен быть жив.
local function find_creature(...)
    local params = { ... }
    for _, p in ipairs(params) do
        local o = val(p)
        if o ~= nil and type(o) ~= "number" and type(o) ~= "string" then
            local cls = nil
            pcall(function()
                if not (o.IsValid and not o:IsValid()) then
                    cls = o:GetClass():GetFName():ToString()
                end
            end)
            if cls and (cls:find("BP_") or cls:find("Character") or cls:find("Pal")) then
                return pretty(cls)
            end
        end
    end
    return nil
end

log("=== Мод загружен (финал), слушаю события ===")
print("[MiaEvents] events.log -> " .. LOG_PATH .. "\n")

------------------------------------------------------------------------
-- МИР / ВХОД
------------------------------------------------------------------------

-- «Мир готов» — взводится через 10 сек после загрузки GameState. До этого момента
-- (пока персонаж спавнится) регион-хук молчит: overlap стреляет в самый спавн, а
-- чтение полей полусозданной пешки уронило игру 30.07. Отсекаем весь спавн-всплеск.
local world_ready = false

pcall(function()
    RegisterInitGameStatePreHook(function()
        log("МИР загружается (GameState init)...")
        world_ready = false                     -- новый мир — снова ждём спавн
        pcall(function()
            ExecuteWithDelay(10000, function() world_ready = true end)
        end)
    end)
end)

-- Игрок появился в мире / респавн (ClientRestart). Steam-имя игрока.
-- ЗАБЛОКИРОВАНО 2026-07-23 по просьбе Олега: ClientRestart дёргается на КАЖДУЮ
-- посадку/слезание с пала верхом — спамит «респавн». Сам хук оставляем (на нём
-- висит регистрация поимки ниже), просто НЕ логируем это событие. Вернуть — раскомментировать log().
hook("/Script/Engine.PlayerController:ClientRestart", function(Context)
    -- local name = "?"
    -- pcall(function()
    --     local pc = Context:get()
    --     local ps = pc.PlayerState
    --     if ps and ps:IsValid() then name = ps.PlayerNamePrivate:ToString() end
    -- end)
    -- log("ПОЯВИЛСЯ / РЕСПАВН (steam): " .. tostring(name))
end)

------------------------------------------------------------------------
-- ЧАТ + системные сообщения (вход/выход, японская локаль)
------------------------------------------------------------------------

local function parse_system(message)
    local w = message:match("^(.-)が") or "?"
    if message:find("ログイン") then
        log("ВОШЁЛ В ИГРУ (game): " .. w); return true
    elseif message:find("ログアウト") then
        log("ВЫШЕЛ ИЗ ИГРЫ (game): " .. w); return true
    end
    return false
end

hook("/Script/Pal.PalGameStateInGame:BroadcastChatMessage", function(self, ChatMessage)
    local sender, message = "?", "?"
    pcall(function()
        local m = ChatMessage:get()
        sender  = m.Sender:ToString()
        message = m.Message:ToString()
    end)
    if sender == "SYSTEM" and parse_system(message) then return end
    log("ЧАТ | " .. tostring(sender) .. ": " .. tostring(message))
end)

------------------------------------------------------------------------
-- БОЙ / СМЕРТЬ / УРОН — живые хуки, дёргаются в одиночной игре.
--
-- ГЛАВНЫЙ УРОК КРАШЕЙ: НЕЛЬЗЯ читать вид у трупа. В момент смерти актёр уже
-- разрушается движком, любое обращение к нему (даже GetClass) = вылет на C++,
-- pcall туда не дотягивается. Так люди это и НЕ делают.
-- ПРАВИЛЬНЫЙ способ (как в рабочих модах): запомнить вид ПОКА ВРАГ ЖИВ — в момент
-- урона по нему, — а на смерти просто напечатать запомненное, труп не трогая.
------------------------------------------------------------------------

-- Вид существа из его КОМПОНЕНТА-ПАРАМЕТРА (UPalCharacterParameterComponent).
-- Цепочка из дампа: comp:GetIndividualParameter() -> :GetCharacterID() (FName -> вид).
-- Параметр-объект — это данные (UObject), он переживает смерть актёра, читать безопасно.
-- Сырой CharacterID существа из его компонента (ДО перевода/среза префикса босса).
local function comp_raw(comp)
    local sp = nil
    pcall(function()
        if comp == nil then return end
        if comp.IsValid and not comp:IsValid() then return end
        local ind = comp:GetIndividualParameter()
        if ind and ind:IsValid() then
            sp = s(ind:GetCharacterID())
        end
    end)
    return sp
end

local function comp_species(comp)
    return pal_ru(comp_raw(comp))
end

-- Кэш «последний враг, которому нанесли урон». Заполняется на УРОНЕ (враг жив),
-- печатается на СМЕРТИ. Труп при этом не трогаем вообще.
local last_enemy = nil
-- Кто последним ударил этого врага: true = ты/твой пал, false = НЕ ты (дикие дерутся
-- между собой), nil = не удалось определить. Печатается вместе с «ПАЛ УБИТ».
local last_enemy_mine = nil

-- Дебаунс «твой активный пал слёг»: чтобы не орать на каждый удар по упавшему палу.
local otomo_down = false

-- «Это моя сторона?» — статик-хелпер игры UPalUtility:IsPlayerOrOtomo(actor):
-- true, если актёр — сам игрок ИЛИ его пал-компаньон. Так отличаем «я убил» от
-- «дикие загрызли друг друга рядом». Актёр-атакующий на уроне ЖИВ — читать безопасно.
local pal_util = nil
local function is_mine(actor)
    if actor == nil then return nil end
    local res = nil
    pcall(function()
        if pal_util == nil then
            pal_util = StaticFindObject("/Script/Pal.Default__PalUtility")
        end
        if pal_util then res = pal_util:IsPlayerOrOtomo(actor) end
    end)
    return res
end

-- Урон по любому персонажу. self = компонент того, КОГО бьют (он жив в этот миг).
hook("/Script/Pal.PalCharacterParameterComponent:OnDamage", function(self, dmg)
    pcall(function()
        local comp = val(self)
        if comp == nil then return end
        local is_otomo = false
        pcall(function() is_otomo = comp:IsOtomo() end)
        if is_otomo then
            -- ТВОЙ пал (компаньон) получил урон. Если упал в ноль — сообщаем ОДИН раз.
            -- Компонент ЖИВОЙ в этот миг (это его бьют) — читать безопасно, труп не трогаем.
            local down = false
            pcall(function() down = comp:IsDyingHPZero() end)
            if not down then
                local rate = nil
                pcall(function() rate = comp:GetHPRate() end)
                if type(rate) == "number" and rate <= 0 then down = true end
            end
            if down and not otomo_down then
                otomo_down = true
                local sp = comp_species(comp)
                log("ТВОЙ ПАЛ СЛЁГ" .. (sp and (": " .. sp) or ""))
            elseif not down then
                otomo_down = false          -- жив/подлечился — снимаем дебаунс
            end
            return                          -- своего пала во «врагов» не пишем
        end
        local raw = comp_raw(comp)
        if raw and raw ~= "" then
            last_enemy = boss_tag(raw) .. pal_ru(raw)   -- босса не теряем
            -- кто именно бьёт этого врага: ты/твой пал или дикие между собой
            local d = val(dmg)
            local atk = nil
            pcall(function() atk = d and d.Attacker or nil end)
            last_enemy_mine = is_mine(atk)
        end
    end)
end)

-- «Кого я убил». DropItem_FromEnemyDeath надёжно дёргается на убийстве в одиночке,
-- НО его EnemyActor — уже труп, трогать нельзя (это и был краш). Поэтому актёр
-- игнорируем полностью, печатаем запомненный на уроне вид.
hook("/Script/Pal.PalUtility:DropItem_FromEnemyDeath", function()
    -- атрибуция: моё убийство печатаем как раньше («ПАЛ УБИТ»), а если враг пал
    -- НЕ от тебя (дикие сцепились рядом) — помечаем, чтоб Мия не приписывала это тебе.
    local tail = last_enemy and (": " .. last_enemy) or ""
    if last_enemy_mine == false then
        log("ПАЛ ПОГИБ РЯДОМ (не тобой)" .. tail)
    else
        log("ПАЛ УБИТ" .. tail)
    end
    last_enemy = nil
    last_enemy_mine = nil
end)

-- Дедуп смертей МЕЖДУ каналами: одну и ту же гибель ловят до трёх хуков сразу
-- (серверный OnDeadPlayer_Server, клиентский kill-feed, мультикаст OnDyingDeadEnd_All).
-- Ключ — имя погибшего ("__me" для смерти без имени, своей). Кто успел первым, тот
-- и пишет; остальные в пределах окна молчат. Так на своём мире нет тройных записей,
-- а на чужом сервере смерть всё равно фиксируется тем каналом, который там живой.
local recent_death = {}
local DEATH_DEDUP_SEC = 8
local function death_seen(key)
    if key == nil or key == "" then return false end
    local t = recent_death[key]
    return t ~= nil and (os.time() - t) <= DEATH_DEDUP_SEC
end
local function death_mark(key)
    if key ~= nil and key ~= "" then recent_death[key] = os.time() end
end

-- «Кто убил меня». Из дампа: OnDeadPlayer_Server(FPalDeadInfo DeadInfo).
-- В структуре есть LastAttacker (AActor*) — это АТАКУЮЩИЙ, он жив, читать безопасно.
-- Больше не нужен хак с запоминанием урона: убийца лежит прямо в событии смерти.
hook("/Script/Pal.PalPlayerCharacter:OnDeadPlayer_Server", function(self, DeadInfo)
    local killer = nil
    pcall(function()
        local di = val(DeadInfo)
        if di then killer = actor_species(di.LastAttacker) end
    end)
    death_mark("__me")                      -- этот канал первый и самый информативный
    if killer then log(">> ИГРОК УМЕР, убийца: " .. killer)
    else            log(">> ИГРОК УМЕР") end
end)

-- СМЕРТИ НА ЧУЖОМ СЕРВЕРЕ. Все хуки выше (*_Server, DropItem_FromEnemyDeath) —
-- серверная авторитетная логика: на СВОём хостящемся мире (сервер = ты) они
-- дёргаются, а на ЧУЖОМ сервере ты гость-клиент, и они срабатывают у ХОЗЯИНА,
-- не у тебя — оттого смерти там не фиксировались. Ловим клиентский kill-feed:
-- сервер шлёт его каждому клиенту (для плашек «X убил Y»). Из дампа —
-- APalPlayerController: AddKillLog_Client / AddDeathLog_Client / AddHardcorePlayerDeathLog_Client,
-- параметр FPalKillLogDisplayData со СТРОКОВЫМИ полями (AttackerName / KilledCharacterName)
-- + FName-коды вида (AttackerCharacterID / KilledCharacterID) — читать безопасно, это данные,
-- не труп. В синглплеере этот feed не вызывается (проверено), так что двойных записей на
-- своём мире не будет — механизмы взаимоисключающие.
local last_feed = nil          -- дедуп: kill-feed иногда шлёт одну строку дважды
local function kill_feed(tag, data)
    pcall(function()
        local d = val(data)
        if d == nil then return end
        -- имя атакующего: сперва читаемое имя (игрок/NPC), иначе вид по коду
        local atk = s(d.AttackerName)
        if atk == nil or atk == "" then atk = pal_ru(pretty(s(d.AttackerCharacterID))) end
        -- имя погибшего: так же
        local vic = s(d.KilledCharacterName)
        if vic == nil or vic == "" then vic = pal_ru(pretty(s(d.KilledCharacterID))) end
        local line
        if atk and atk ~= "" and vic and vic ~= "" then
            line = tag .. atk .. " -> убил -> " .. vic
        elseif vic and vic ~= "" then
            line = tag .. "жертва: " .. vic
        elseif atk and atk ~= "" then
            line = tag .. "убийца: " .. atk
        else
            return
        end
        if line == last_feed then return end   -- та же строка подряд — пропускаем
        last_feed = line
        death_mark(vic)                        -- чтобы мультикаст ниже не написал ту же смерть второй раз
        log(line)
    end)
end
hook("/Script/Pal.PalPlayerController:AddKillLog_Client",
    function(self, KillLogData) kill_feed(">> УБИЙСТВО (сервер): ", KillLogData) end)
hook("/Script/Pal.PalPlayerController:AddDeathLog_Client",
    function(self, DeathLogData) kill_feed(">> СМЕРТЬ (сервер): ", DeathLogData) end)
hook("/Script/Pal.PalPlayerController:AddHardcorePlayerDeathLog_Client",
    function(self, DeathLogData) kill_feed(">> ИГРОК ПОГИБ НАВСЕГДА (хардкор): ", DeathLogData) end)

-- ВТОРОЙ КАНАЛ СМЕРТИ ИГРОКА (2026-07-26) — мультикаст OnDyingDeadEnd_All.
-- Из дампа: APalPlayerCharacter:OnDyingDeadEnd_All(APalPlayerCharacter* PlayerCharacter,
-- FPalDyingEndInfo DyingEndInfo). Суффикс _All = NetMulticast: сервер рассылает вызов
-- ВСЕМ клиентам — значит он долетает и до тебя-гостя на чужом сервере, там, где
-- серверные *_Server хуки исполняются у хозяина и до нас не доходят. Именно этим ловил
-- смерть прошлогодний ChatLogger. Убийцы в FPalDyingEndInfo нет (там лишь FPalInstanceID),
-- зато есть надёжный ФАКТ смерти — «кто убил» добавляет kill-feed выше.
-- Труп не трогаем: имя берём из PlayerState (это данные, они переживают актёра),
-- «мой ли персонаж» — через IsLocallyControlled() у пешки. Чужие смерти пропускаем:
-- их и так показывает kill-feed, незачем спамить на людном сервере.
hook("/Script/Pal.PalPlayerCharacter:OnDyingDeadEnd_All", function(self, PlayerCharacter, DyingEndInfo)
    pcall(function()
        local pc = val(PlayerCharacter)
        if pc == nil then pc = val(self) end
        if pc == nil then return end
        local mine = nil
        pcall(function() mine = pc:IsLocallyControlled() end)
        if mine == false then return end        -- чужой игрок — молчим
        local name = nil
        pcall(function()
            local ctrl = pc.Controller
            if ctrl and ctrl:IsValid() then
                local ps = ctrl.PlayerState
                if ps and ps:IsValid() then name = s(ps.PlayerNamePrivate) end
            end
        end)
        if death_seen("__me") or death_seen(name) then return end
        death_mark("__me"); death_mark(name)
        log(">> ИГРОК УМЕР" .. ((name and name ~= "") and (" (" .. name .. ")") or ""))
    end)
end)

-- НИЗКОЕ HP ИГРОКА — «вот-вот погибнет». OnDamagePlayer_Server дёргается ТОЛЬКО по игроку
-- (в одиночке сервер = ты, работает как OnDeadPlayer_Server). Игрок ЖИВ (лишь ранен) —
-- читаем HP-рейт через ЖИВОЙ компонент, труп не трогаем. Дебаунс: одно предупреждение,
-- пока HP не поднимется обратно выше порога.
local LOW_HP = 0.25
local low_hp_warned = false
hook("/Script/Pal.PalPlayerCharacter:OnDamagePlayer_Server", function(self)
    pcall(function()
        local pc = val(self)
        if pc == nil then return end
        local comp = pc:GetCharacterParameterComponent()
        if not (comp and comp:IsValid()) then return end
        local rate = comp:GetHPRate()
        if type(rate) ~= "number" then return end
        if rate > 0 and rate <= LOW_HP then
            if not low_hp_warned then
                low_hp_warned = true
                log(string.format("!! НИЗКОЕ HP ИГРОКА: %d%% — вот-вот погибнет!", math.floor(rate * 100 + 0.5)))
            end
        elseif rate > LOW_HP then
            low_hp_warned = false           -- подлечился — снимаем дебаунс
        end
    end)
end)

------------------------------------------------------------------------
-- ЛЕВЕЛАП — сигнатура из дампа: OnUpdateLocalPlayerLevel(addLevel, nowLevel).
-- nowLevel — уровень ДО апа (значение на момент вызова), addLevel — прибавка.
-- Настоящий НОВЫЙ уровень = nowLevel + addLevel, его и показываем.
------------------------------------------------------------------------

hook("/Script/Pal.PalTechnologyData:OnUpdateLocalPlayerLevel", function(self, addLevel, nowLevel)
    local now, add = nil, nil
    pcall(function() now = val(nowLevel) end)
    pcall(function() add = val(addLevel) end)
    local shown = now
    if now and add then shown = now + add end
    log("ЛЕВЕЛАП -> уровень " .. tostring(shown) .. (add and (" (+" .. tostring(add) .. ")") or ""))
end)

------------------------------------------------------------------------
-- ОЧКИ ТЕХНОЛОГИЙ. В дампе у UPalTechnologyData два счётчика: обычные
-- (TechnologyPoint — за уровни) и ДРЕВНИЕ (bossTechnologyPoint — за первую
-- победу над боссом и за древние руководства). Значения берём геттерами
-- GetTechnologyPoints / GetBossTechnologyPoints и печатаем только ПРИРОСТ,
-- иначе будет спам одинаковых чисел. Точек обновления в дампе три — вешаемся
-- на все, какая живая, та и сработает: дельта-фильтр задвоиться не даст.
------------------------------------------------------------------------

local tech_pts, boss_pts = nil, nil

local function tech_report(self)
    pcall(function()
        local o = val(self)
        if o == nil then return end
        local t, b = nil, nil
        pcall(function() t = val(o:GetTechnologyPoints()) end)
        pcall(function() b = val(o:GetBossTechnologyPoints()) end)
        if type(b) == "number" and type(boss_pts) == "number" and b > boss_pts then
            log("⚙ ОЧКИ ДРЕВНИХ ТЕХНОЛОГИЙ +" .. (b - boss_pts) .. " (всего " .. b .. ")")
        end
        if type(t) == "number" and type(tech_pts) == "number" and t > tech_pts then
            log("⚙ ОЧКИ ТЕХНОЛОГИЙ +" .. (t - tech_pts) .. " (всего " .. t .. ")")
        end
        if type(t) == "number" then tech_pts = t end
        if type(b) == "number" then boss_pts = b end
    end)
end

hook("/Script/Pal.PalTechnologyData:OnUpdateTechnologyPoint__DelegateSignature",
     function(self) tech_report(self) end)
hook("/Script/Pal.PalTechnologyData:OnRep_TechnologyPoint",
     function(self) tech_report(self) end)
hook("/Script/Pal.PalTechnologyData:OnRep_BossTechnologyPoint",
     function(self) tech_report(self) end)

------------------------------------------------------------------------
-- ПОИМКА ПАЛА — «кого поймал». Из дампа: у сферы (BP_PalSphere_Body_C) есть поле
-- targetHandle (UPalIndividualCharacterHandle). Цепочка:
--   handle:TryGetIndividualParameter() -> :GetCharacterID() -> FName -> вид.
-- Сфера в момент поимки ЖИВА — читать безопасно.
-- BP-класс грузится не на старте, вешаем ПОСЛЕ появления игрока, один раз.
------------------------------------------------------------------------

-- Индекс словаря пассивок в нижнем регистре — реальные коды приходят в разном
-- регистре/разделителе ("CraftSpeed_up1" против "..._UP_1"). Строим один раз лениво.
local PASSIVES_RU_LC = nil
local function passives_lc()
    if PASSIVES_RU_LC == nil then
        PASSIVES_RU_LC = {}
        for k, v in pairs(PASSIVES_RU) do PASSIVES_RU_LC[string.lower(k)] = v end
    end
    return PASSIVES_RU_LC
end

-- Код пассивки -> русское имя. Реальные коды часто идут с суффиксом "_PAL"
-- (ElementResist_Ice_1_PAL) — срезаем его перед поиском. Регистр игнорируем.
-- Нет в словаре -> вернуть исходный код (безопасный откат).
local function passive_ru(nm)
    if PASSIVES_RU[nm] then return PASSIVES_RU[nm] end
    local base = nm:gsub("_PAL$", "")                  -- ..._1_PAL -> ..._1
    if PASSIVES_RU[base] then return PASSIVES_RU[base] end
    return passives_lc()[string.lower(nm)] or passives_lc()[string.lower(base)] or nm
end

-- Конвертер элемента TArray<FName> (пассивка) -> строка.
local function conv_fname(el)
    local nm = nil
    pcall(function() nm = el:get():ToString() end)     -- элемент = RemoteUnrealParam(FName)
    if not nm then pcall(function() nm = el:ToString() end) end  -- фолбэк: элемент = FName
    if nm and nm ~= "None" and nm ~= "" then return passive_ru(nm) end
    return nil
end

-- Конвертер элемента TArray<EPalWazaID> (приём) -> имя через WAZA_NAMES.
local function conv_waza(el)
    local id = nil
    pcall(function() id = el:get() end)
    if type(id) ~= "number" then pcall(function() id = el end) end  -- фолбэк: элемент уже число
    if type(id) == "number" and id ~= 0 then
        local en = WAZA_NAMES[id]
        if en then
            if WAZA_RU[en] then return WAZA_RU[en] end
            -- нет русского: у уникальных приёмов режем префикс Unique_<Пал>_ -> хвост
            local tail = en:match("^Unique_[^_]+_(.+)$")
            if tail then return WAZA_RU[tail] or tail end
            return en
        end
        return "waza#" .. id
    end
    return nil
end

-- Прочитать TArray-возврат UФункции. UE4SS отдаёт массив особым объектом, не как
-- простое число, — поэтому числа-геттеры работают, а массивы молча пустуют.
-- Пробуем ДВА способа обхода — ForEach и индексами [1..num]; какой-то да сработает.
-- (Диагностику [DIAG] убрали 2026-07-23 — проверено, обход работает: num==собрано.)
local function read_list(getter, conv)
    local ok, arr = pcall(getter)
    if not ok or arr == nil then return {} end
    local num = nil
    pcall(function() num = arr:GetArrayNum() end)
    if num == nil then pcall(function() num = #arr end) end
    local out = {}
    pcall(function()                                    -- способ 1: ForEach
        arr:ForEach(function(_, el)
            local v = conv(el)
            if v then out[#out + 1] = v end
        end)
    end)
    if #out == 0 and type(num) == "number" and num > 0 then
        for i = 1, num do                               -- способ 2: индексами
            pcall(function()
                local v = conv(arr[i])
                if v then out[#out + 1] = v end
            end)
        end
    end
    return out
end

-- Собрать характеристики пойманного пала из его IndividualParameter (объект-данные, жив).
-- Все геттеры из CXX-дампа класса UPalIndividualCharacterParameter. Каждый в pcall —
-- если поле не прочитается, просто не попадёт в строку, мод не упадёт.
local function pal_info(param)
    local parts = {}
    local function add_num(fn, fmt)
        local v = nil
        pcall(function() v = fn() end)
        if type(v) == "number" then parts[#parts + 1] = string.format(fmt, v) end
    end
    add_num(function() return param:GetLevel() end,       "ур.%d")
    add_num(function() return param:GetRank() end,        "ранг %d")
    add_num(function() return param:GetMaxHP() end,       "HP %d")
    local atk, shot = nil, nil
    pcall(function() atk = param:GetMeleeAttack() end)
    pcall(function() shot = param:GetShotAttack() end)
    if type(atk) == "number" then
        parts[#parts + 1] = "атака " .. atk .. (type(shot) == "number" and ("/" .. shot) or "")
    end
    add_num(function() return param:GetDefense() end,     "защита %d")
    local rare = false
    pcall(function() rare = param:IsRarePal() end)
    if rare then parts[#parts + 1] = "★РЕДКИЙ" end
    -- пассивки: TArray<FName>, приёмы: TArray<EPalWazaID>.
    -- Читаем через read_list (диагностика + два способа обхода массива).
    local skills = read_list(function() return param:GetPassiveSkillList() end, conv_fname)
    if #skills > 0 then parts[#parts + 1] = "пассивки: " .. table.concat(skills, ", ") end
    local waza = read_list(function() return param:GetEquipWaza() end, conv_waza)
    if #waza > 0 then parts[#parts + 1] = "приёмы: " .. table.concat(waza, ", ") end
    return table.concat(parts, ", ")
end

-- Сырые конвертеры — БЕЗ перевода в русское имя. Нужны техническому дампу, чтобы
-- видеть латинские коды один в один, как их отдаёт игра.
local function conv_fname_raw(el)
    local nm = nil
    pcall(function() nm = el:get():ToString() end)
    if not nm then pcall(function() nm = el:ToString() end) end
    if nm and nm ~= "None" and nm ~= "" then return nm end
    return nil
end
local function conv_waza_raw(el)
    local id = nil
    pcall(function() id = el:get() end)
    if type(id) ~= "number" then pcall(function() id = el end) end
    if type(id) == "number" and id ~= 0 then return tostring(id) end
    return nil
end

-- Технический дамп пойманного пала в tech.log (мимо модели). Повод — 2026-07-27:
-- у Ламболла легендарная пассивка «Демон Бог» не попала в лог. Дампим ДВА источника
-- пассивок с их счётчиками — сразу видно, недобирает ли метод GetPassiveSkillList()
-- или пустое само поле .PassiveSkillList. Всё сырьём, всё в pcall — мод не уронит.
local function tech_dump_pal(param)
    if not param then return end
    tech("=== ПОЙМАН ПАЛ (сырьё) ===")
    pcall(function() tech("  CharacterID = " .. tostring(s(param:GetCharacterID()))) end)
    local m = read_list(function() return param:GetPassiveSkillList() end, conv_fname_raw)
    tech("  пассивки GetPassiveSkillList(): [" .. #m .. "]  " .. table.concat(m, "  |  "))
    local fld = read_list(function() return param.PassiveSkillList end, conv_fname_raw)
    tech("  пассивки .PassiveSkillList:     [" .. #fld .. "]  " .. table.concat(fld, "  |  "))
    local w = read_list(function() return param:GetEquipWaza() end, conv_waza_raw)
    tech("  приёмы GetEquipWaza():          [" .. #w .. "]  " .. table.concat(w, "  |  "))
    local function tnum(fn, tag)
        local v = nil
        pcall(function() v = fn() end)
        if v ~= nil then tech("  " .. tag .. " = " .. tostring(v)) end
    end
    tnum(function() return param:GetLevel() end,     "Level")
    tnum(function() return param:GetRank() end,      "Rank")
    tnum(function() return param:GetMaxHP() end,     "MaxHP")
    tnum(function() return param:GetMeleeAttack() end,"MeleeAttack")
    tnum(function() return param:GetShotAttack() end, "ShotAttack")
    tnum(function() return param:GetDefense() end,   "Defense")
    tnum(function() return param:IsRarePal() end,    "IsRarePal")
end

------------------------------------------------------------------------
-- ЧЬЯ СФЕРА (2026-07-26). На чужом сервере CaptureSuccessEvent дёргается на
-- КАЖДОЙ сфере в зоне видимости, включая чужие — соседский улов приходил в лог
-- как наш. Ищем хозяина сферы тремя способами по убыванию надёжности:
--   1) Instigator — тот, кто бросил; реплицируется всем клиентам;
--   2) Owner — владелец актёра;
--   3) FindOwnerPlayer() — собственная BP-функция сферы (её же способ).
-- Ответ: true — моя, false — чужая, nil — не определилось.
-- Не определилось => пишем как раньше: в одиночке чужих нет, регресса не будет.
-- Объекты трогаем только через live_obj (урок краша 12:16), всё в pcall.
local function pawn_is_mine(p)
    if not live_obj(p) then return nil end
    local mine = nil
    pcall(function() mine = p:IsLocallyControlled() end)
    if type(mine) == "boolean" then return mine end
    return nil
end

local function sphere_owner_mine(sphere)
    if not live_obj(sphere) then return nil, "мёртвая сфера" end
    local r = nil
    pcall(function() r = pawn_is_mine(val(sphere.Instigator)) end)
    if r ~= nil then return r, "instigator" end
    pcall(function() r = pawn_is_mine(val(sphere:GetOwner())) end)
    if r ~= nil then return r, "owner" end
    pcall(function() r = pawn_is_mine(val(sphere:FindOwnerPlayer())) end)
    if r ~= nil then return r, "findowner" end
    return nil, "не определилось"
end

local capture_hooked = false
hook("/Script/Engine.PlayerController:ClientRestart", function()
    if capture_hooked then return end
    capture_hooked = true
    local ok = pcall(function()
        RegisterHook("/Game/Pal/Blueprint/Weapon/Other/NewPalSphere/BP_PalSphere_Body.BP_PalSphere_Body_C:CaptureSuccessEvent",
            function(self)
                local sphere = val(self)
                local mine, how = sphere_owner_mine(sphere)
                local species, info = nil, ""
                pcall(function()
                    local handle = sphere.targetHandle
                    if handle and handle:IsValid() then
                        local param = handle:TryGetIndividualParameter()
                        if param and param:IsValid() then
                            local raw = s(param:GetCharacterID())
                            species = boss_tag(raw) .. pal_ru(raw)   -- босса не теряем
                            info = pal_info(param)
                            tech_dump_pal(param)                     -- сырьё в tech.log
                        end
                    end
                end)
                -- Чужую поимку НЕ прячем совсем, а пишем отдельной строкой: видно в
                -- логе, что фильтр отработал, а ассистент её глушит (ignore_event).
                if mine == false then
                    log("ЧУЖАЯ ПОИМКА (сосед по серверу)" .. (species and (": " .. species) or ""))
                    return
                end
                -- если хозяин не определился — пишем как раньше, а способ кладём
                -- только в UE4SS.log: events.log читает модель, туда служебное не льём
                if mine == nil then
                    print("[MiaEvents] сфера: хозяин не определился (" .. tostring(how) .. ")\n")
                end
                log("ПОЙМАН ПАЛ" .. (species and (": " .. species) or " (вид не прочитался)")
                    .. (info ~= "" and (" [" .. info .. "]") or ""))
            end)
    end)
    if ok then log("хук OK   -> BP_PalSphere_Body_C:CaptureSuccessEvent (поимка)")
    else       log("хук FAIL -> BP_PalSphere_Body_C:CaptureSuccessEvent (поимка)") end
end)

------------------------------------------------------------------------
-- МИР: боссы, вылупление яиц
------------------------------------------------------------------------

-- РАЗВЕДКА имени босса (2026-07-27, после краша 15:42).
-- Прошлый раз я вслепую ДЁРГАЛА Get-методы на объекте боя — один разыменовал
-- битый указатель и уронил движок в C++, мимо всех pcall. Урок: pcall НЕ спасает
-- от нативного краша. Поэтому здесь мы объект боя только СМОТРИМ, ничего не зовём:
--   * тип сырого параметра;  * жив ли объект (live_obj -> IsValid);
--   * его полное имя и класс (стандартная безопасная интроспекция UObject);
--   * какие нужные методы вообще есть — через ИНДЕКСИРОВАНИЕ (obj[name] ~= nil),
--     это метаданные рефлексии, а НЕ вызов метода на игровой памяти.
-- Всё в tech.log (модель не видит), всё в pcall. По логу глазами увидим
-- безопасный канал к имени босса — и уже тогда достанем его без вылета.
-- ⚠️ ВЫВОД 2026-07-27 15:57: имя босса отсюда НЕ достаётся. Даже безобидная
-- развёртка val(p1) (не вызов метода!) роняет движок нативно — access violation
-- мимо всех pcall (pcall ловит только Lua-ошибки, не C++-краш). Проверено дважды:
-- сначала дёрганьем Get-методов, потом чистой разведкой — оба вылета на первом же
-- КАСАНИИ p1. Объект босса в этом хуке — недоступный указатель. Не трогаем ВООБЩЕ.
-- Хук снова минимальный: только факт «бой начался», без имени.
-- 🏛 tower_fight_t: время последнего F по башне-боссу. Объявлено ЗДЕСЬ (до хуков
-- телепорта и «бой начался», что ниже по файлу), чтобы они его видели и глушили
-- каскад на входе в башню (просьба Олега 27.07: вход в башню дробился на 4 реплики
-- внахлёст — двойное «впереди бой» + телепорт-в-арену + «бой начался»).
local tower_fight_t = 0
hook("/Script/Pal.PalBossBattleSequencer:SetBossCharacter", function(self, p1, p2)
    -- Если только что вошли в башню-босса — «впереди бой в башне — Имя» уже сказано
    -- на входе, а generic «бой начался» лишний и лишь перебивает. Глушим у башни.
    -- Для НЕ-башенных боссов (tower_fight_t давно) — как раньше, объявляем бой.
    if os.time() - tower_fight_t <= 40 then return end
    log("БОСС: бой начался")
end)

-- Вылупление пала из яйца — хук ниже, после saveparam_info (переиспользуем карточку).

------------------------------------------------------------------------
-- РАСШИРЕНИЕ 2026-07-23: пачка событий из CXX-дампа игры.
-- ВСЁ здесь — события-ФАКТЫ: НЕ трогаем умирающие объекты, читаем только
-- простые параметры (числа/enum/bool/FName), пришедшие в само событие.
-- Правило имени класса движка: UPalX/APalX -> срезаем только U/A -> PalX.
-- Часть имён — мультикаст-делегаты (OnXxxDelegate): в UE4SS хукаются НЕ всегда.
-- Каждый хук пишет OK/FAIL при загрузке; по логу увидим, что реально стреляет.
------------------------------------------------------------------------

-- Развернуть RemoteUnrealParam и превратить в строку (FName/FString/число/bool).
local function anystr(p)
    return s(val(p))
end

-- Навесить простое событие: лог факта + опц. суффикс из reader(p1,p2,p3) (сырые параметры).
local function simple(path, label, reader)
    hook(path, function(self, p1, p2, p3)
        local suffix = ""
        if reader then
            local ok, r = pcall(function() return reader(p1, p2, p3) end)
            if ok and r then suffix = " " .. tostring(r) end
        end
        log(label .. suffix)
    end)
end

-- ВРЕМЯ СУТОК
simple("/Script/Pal.PalTimeManager:OnNightStartDelegate", "НАСТУПИЛА НОЧЬ")
simple("/Script/Pal.PalTimeManager:OnNightEndDelegate",   "НАСТУПИЛ ДЕНЬ")

-- СТАТУСЫ ТЕЛА (замерзание, голод, промокание, перегруз, сон, перегрев)
simple("/Script/Pal.PalBodyTemperatureComponent:OnChangeBodyStateDelegate", "СОСТОЯНИЕ ТЕЛА (жара/холод), код:",
    function(p1) return anystr(p1) end)
simple("/Script/Pal.PalIndividualCharacterParameter:UpdateHungerTypeDelegate", "ГОЛОД сменился, код:",
    function(p1, p2) return (anystr(p2) or "?") .. "->" .. (anystr(p1) or "?") end)
-- ПРОМОКАНИЕ убрано 2026-07-23 по просьбе Олега — спамило «мокрый/сухой» на каждый чих.
simple("/Script/Pal.PalPlayerCharacter:OnOverWeightInventory", "ПЕРЕГРУЗ инвентаря",
    function(p1) return "(вес " .. (anystr(p1) or "?") .. ")" end)
simple("/Script/Pal.PalPlayerCharacter:OnSleepPlayer", "игрок УСНУЛ / вырубился")
simple("/Script/Pal.PalPartnerSkillParameterComponent:OnOverheat", "пал-партнёр ПЕРЕГРЕЛСЯ (стамина)")

-- ПАЛЫ: ранг, уровень, повержение противника
simple("/Script/Pal.PalIndividualCharacterParameter:UpdateRankDelegate", "РАНГ пала вырос:",
    function(p1, p2) return (anystr(p2) or "?") .. "->" .. (anystr(p1) or "?") end)
simple("/Script/Pal.PalIndividualCharacterParameter:UpdateLevelDelegate", "ПАЛ вырос до уровня",
    function(p1, p2) return anystr(p2) end)
simple("/Script/Pal.PalPlayerCharacter:OnDefeatCharacterDelegate", "повержен противник")

-- БОССЫ: победа/поражение над боссом (в т.ч. башенным).
-- Причина, почему победа раньше НЕ ловилась: мультикаст-делегаты
-- (OnLocalPlayerBossBattleSuccessDelegate, OnCombatStart/OnCombatEnd) в одиночной
-- игре регистрируются (лог: "хук OK"), но по факту НЕ дёргаются — молчат.
-- Рабочий канал — обычные ФУНКЦИИ, которые игра реально зовёт в конце боя:
--   * UPalBossBattleSequencer:OnCombatFinish(Result)  — тот же класс, что рабочий
--     SetBossCharacter ("БОСС: бой начался"), значит секвенсор для этого боя живой;
--   * UPalNetworkBossBattleComponent:CombatResult_ToClient(BossType, Result) — итог
--     приходит клиенту по сети.
-- Результат — enum EPalBossBattleCombatResult: None=0, Won=1, TimeUp=2, AllDead=3.
-- 🏛 БИБЛИОТЕКА БАШЕН-БОССОВ (идея Олега 2026-07-27). Имя босса из хука боя
-- (SetBossCharacter) НЕ достаётся — объект боя роняет движок при любом касании,
-- даже безобидной развёрткой val() (краш проверен дважды, access violation мимо
-- всех pcall). ОБХОД: у каждой башни на карте свой ПОСТОЯННЫЙ отпечаток в full —
-- BP_PalBossTower_C_UAID_xxx (виден в F-разведке на ВХОДЕ, где объект башни жив и
-- читается безопасно). Ключ стабилен: та же башня — тот же UAID. Заполняется вручную:
-- Олег видит имя босса на экране → вписываем сюда ключ→имя, и со следующего раза
-- (и на всех прочих башнях) победа звучит с именем. Не гадаем: пока ключа тут нет —
-- победа просто без имени (как сейчас), а UAID падает в tech.log для заполнения.
-- Ключ = ТОЛЬКО стабильная hex-часть UAID (без хвоста-суффикса _NNN: он instance-id
-- и теоретически может смениться; hex-GUID — persistent, вечный). Заполнено по логам 27.07.
local TOWER_BOSSES = {
    ["50EBF65A10EA347101"] = "Зоя и Гризболт",   -- башня Rayne Syndicate (1-я, у базы)
    ["50EBF656371D468C01"] = "Лили и Лилин",      -- Free Pal Alliance, «цветочная» (2-я) — рус. написание сверить с экраном
}
local pending_tower_key = nil    -- ключ последней башни, в которую вошли через F
local pending_tower_t   = 0      -- время входа (окно давности для связки с победой)

local last_boss_result_t = 0
local function boss_result_word(r)
    local v = anystr(r) or ""
    if v:find("Won")     or v == "1" then return "★БОСС ПОБЕДА НАД БОССОМ! (зачистка/первая победа)" end
    if v:find("TimeUp")  or v == "2" then return "★БОСС бой с боссом ПРОИГРАН (время вышло)" end
    if v:find("AllDead") or v == "3" then return "★БОСС бой с боссом ПРОИГРАН (все палы пали)" end
    return nil   -- None/0 — не финал, пропускаем
end
local function boss_finish(result_param)
    local word = boss_result_word(result_param)
    if not word then return end
    local now = os.time()
    if now - last_boss_result_t < 8 then return end   -- дедуп: несколько хуков на одну победу
    last_boss_result_t = now
    -- Башенный бой? Если недавно (≤20 мин) заходили в башню-босса через F, подставляем
    -- имя босса из ручной таблицы TOWER_BOSSES по её постоянному UAID-ключу. Имя из
    -- самого боя не достать (краш), а UAID башни — безопасный обходной канал (идея Олега).
    local tower = ""
    if pending_tower_key and (now - pending_tower_t) <= 1200 then
        local nm = TOWER_BOSSES[pending_tower_key]
        if nm then tower = " — " .. nm end
        tech("🏛 ПОБЕДА В БАШНЕ  ключ=" .. pending_tower_key
            .. "  босс=" .. (nm or "НЕИЗВЕСТЕН — впиши имя в TOWER_BOSSES по этому ключу"))
        pending_tower_key = nil
    end
    log(word .. tower)
end

hook("/Script/Pal.PalBossBattleSequencer:OnCombatFinish", function(self, p1)
    boss_finish(p1)
end)
hook("/Script/Pal.PalNetworkBossBattleComponent:CombatResult_ToClient", function(self, p1, p2)
    boss_finish(p2)
end)

-- Старые сигналы боя (часть в синглплеере молчит — оставляем, не мешают, вдруг стрельнут):
simple("/Script/Pal.PalBossBattleManager:OnLocalPlayerBossBattleSuccessDelegate", "★БОСС ПОБЕДА НАД БОССОМ",
    function(p1, p2) return anystr(p2) end)
simple("/Script/Pal.PalBossBattleEventBase:OnCombatStart", "бой с БОССОМ начался")
simple("/Script/Pal.PalRaidBossManager:OnRaidBossBattleStartDelegate",  "РЕЙД-БОСС: бой начался")
simple("/Script/Pal.PalRaidBossManager:OnRaidBossBattleFinishDelegate", "РЕЙД-БОСС: бой окончен")

-- РЕЙДЫ НА БАЗУ
simple("/Script/Pal.PalInvaderManager:BroadcastInvaderArrived", "РЕЙДЕРЫ НА БАЗЕ!")
simple("/Script/Pal.PalInvaderManager:BroadcastInvaderStart",   "объявлено нападение на базу")
simple("/Script/Pal.PalInvaderManager:BroadcastInvaderEnd",     "нападение на базу отбито")

-- МИР: рыбалка, телепорт
simple("/Script/Pal.PalFishShadow:OnFishingStart", "рыбалка: клюёт")
simple("/Script/Pal.PalLevelObjectWarpPointToLocation:OnWarpCompleted", "ТЕЛЕПОРТ завершён")

-- ПРОГРЕСС: квест, достижение, постройка
simple("/Script/Pal.PalLevelObjectQuestItem:OnCompletedQuest", "КВЕСТ выполнен:",
    function(p1) return anystr(p1) end)
simple("/Script/Pal.PalNetworkPlayerComponent:NotifyUnlockAchievement_ToClient", "ДОСТИЖЕНИЕ открыто:",
    function(p1) return anystr(p1) end)
-- ПОСТРОЙКА отключена 2026-07-23 по просьбе Олега — событие избыточно (не показывает,
-- ЧТО именно строишь). Вернём, когда научимся доставать тип постройки.
-- simple("/Script/Pal.PalBuildObject:OnFinishBuildWork_ServerInternal", "ПОСТРОЙКА завершена")

------------------------------------------------------------------------
-- ПОДЗЕМЕЛЬЯ (данжи) — вход/выход. Добавлено 2026-07-23 по просьбе Олега.
-- Из CXX-дампа (Pal.hpp):
--   APalDungeonEntrance:OnResponseDialogEnterDungeon(const bool bResponse)
--   APalDungeonExit:OnResponseDialogExitDungeon(const bool bResponse)
-- Это ответ игрока на диалог «войти/выйти?»: bResponse=true → подтвердил.
-- Читаем ТОЛЬКО bool из параметра — никаких объектов, краш неоткуда взяться.
-- Логируем лишь подтверждение (true), отказ (false) — тишина.
------------------------------------------------------------------------

hook("/Script/Pal.PalDungeonEntrance:OnResponseDialogEnterDungeon", function(self, bResponse)
    local yes = false
    pcall(function() yes = val(bResponse) == true end)
    if yes then log(">> ИГРОК ВОШЁЛ В ПОДЗЕМЕЛЬЕ (данж)") end
end)

hook("/Script/Pal.PalDungeonExit:OnResponseDialogExitDungeon", function(self, bResponse)
    local yes = false
    pcall(function() yes = val(bResponse) == true end)
    if yes then log("<< ИГРОК ВЫШЕЛ ИЗ ПОДЗЕМЕЛЬЯ (данж)") end
end)

------------------------------------------------------------------------
-- ЭКОНОМИКА 2026-07-23 (ПЕРЕПИСАНО на РЕАЛЬНЫЕ функции из CXX-дампа).
-- Прошлая версия висела на ...Delegate — а это СИГНАТУРЫ делегатов, НЕ вызываемые
-- UFunction'ы; RegisterHook их не берёт (все шесть давали FAIL). Теперь цепляемся
-- к настоящим функциям-действиям, которые игра реально вызывает. Все читают только
-- простые данные (FName/число/enum) из живых объектов — трупов не трогаем.
------------------------------------------------------------------------

-- Фильтр «важности» предмета. Олег попросил (2026-07-23) ЗАГЛУШИТЬ спам подбора
-- рядовых ресурсов (дерево/камень/руда/еда/волокно...), оставив только ЦЕННОЕ:
-- сферы, монеты/особую валюту, чертежи/технологии, ключи, реликвии.
-- ВАЖНО: деньги (id "Money") и ЯЙЦА логируются ОТДЕЛЬНЫМИ ветками ВЫШЕ этого
-- фильтра — они сюда не попадают и НЕ режутся. Палы ловятся своими хуками (поимка/
-- покупка) — тоже мимо фильтра. Список подстрок (нижний регистр) легко дополнять.
-- 🔎 РАЗВЕДКА ПРЕДМЕТОВ. Пока true — мод логирует КАЖДЫЙ приходящий предмет (даже
-- «рядовой», не из списка ниже) сырым внутренним id под меткой [РАЗВЕДКА].
-- Нужно, чтобы поймать точный id фрукта умений (Олег сорвёт — увидим строку).
-- Как поймаем id — впишем его в NOTABLE_ITEM и items_ru, а флаг вернём в false.
local DISCOVER_ITEMS = true

local NOTABLE_ITEM = {
    "sphere",       -- пал-сферы всех видов (Pal/Mega/Giga/Hyper/Ultra/Legend Sphere)
    "coin",         -- монеты / особая валюта
    "medal", "ticket",
    "ancient",      -- детали древней цивилизации (очки технологий)
    "technology", "schematic", "blueprint", "recipe",  -- чертежи/технологии
    "key",          -- ключи (подземелья, клетки)
    "relic",
    "skillfruit", "skillcard", "skillunlock",  -- фрукт умений (вероятные id, точный уточним разведкой)
    "fruit",        -- фрукты статов/дружбы (AffectionFruit, Fruit__defense...) — ценные, не рядовой лут
    "expboost",     -- бустеры опыта (ExpBoost_01/02/03)
}
local function notable_item(id)
    if type(id) ~= "string" then return false end
    local low = id:lower()
    for _, sub in ipairs(NOTABLE_ITEM) do
        if low:find(sub, 1, true) then return true end
    end
    return false
end

-- 🌳 ФРУКТ УМЕНИЯ — карта активного приёма с «дерева навыков» или с земли.
-- id вида "SkillCard_WaterGun" -> русское имя приёма через WAZA_RU (нет — код как есть).
-- Возвращает готовую строку лога или nil (если это не карта приёма).
local function skill_fruit_line(id)
    if type(id) ~= "string" then return nil end
    local move = id:match("^SkillCard_(.+)$")
    if not move then return nil end
    return "🌳 ФРУКТ УМЕНИЯ (приём): " .. (WAZA_RU[move] or move)
end

-- 🏛 ТАЙНИК (башенка BP_InteractableBox_C). Просьба Олега 2026-07-27: не «монеты
-- из ниоткуда» + отдельно «чертёж», а ОДНО событие «открыл тайник — а там то-то».
-- Механика: жмёшь F по башне -> открывается окно на 1.5 с, и ВСЕ предметы, что
-- прилетели плашкой за это окно (монеты, чертёж), не логируются по отдельности, а
-- копятся в буфер и уходят одной строкой. Таймер — ExecuteWithDelay (штатный UE4SS).
-- Триггер окна ставится в F-разведке ниже, когда outer цели == BP_LevelObject_ItemPickupTower_C
-- (настоящая башня-тайник; BP_InteractableBox_C оказался верстаком — см. коммент в разведке).
local tainich_active = false
local tainich_items = {}

local function tainich_flush()
    tainich_active = false
    local body = (#tainich_items > 0) and (": " .. table.concat(tainich_items, ", ")) or ""
    log("🏛 ОТКРЫТ ТАЙНИК" .. body)
    tainich_items = {}
end

local function tainich_start()
    if tainich_active then return end                -- окно уже открыто — не рестартим
    local ok = pcall(function() ExecuteWithDelay(1500, tainich_flush) end)
    if ok then
        tainich_active, tainich_items = true, {}
    else
        log("🏛 ОТКРЫТ ТАЙНИК")                        -- нет таймера — хотя бы факт, награда пойдёт как раньше
    end
end

-- 🪂 ГРУЗ ПОДДЕРЖКИ (BP_MapObject_SupplyDrop_C). Просьба Олега 2026-07-27 13:31: редкое
-- ценное событие (падает с неба, вокруг солдаты, внутри хороший лут). Механика та же, что
-- у тайника: F по грузу -> окно 2 с, лут копится в буфер, уходит одной строкой. Отличие:
-- лут груза, похоже, высыпается на землю 3D-предметами и через AddItemGetLog может НЕ
-- прийти (Олег: «подобрал, но не отобразилось») — тогда уйдёт просто факт «🪂 ГРУЗ
-- ПОДДЕРЖКИ вскрыт», как он и просил («хотя бы факт»). Класс общий (BP_InteractableBox_C,
-- как верстак/телепорт), но outer = BP_MapObject_SupplyDrop_C — по нему и вешаем.
local supply_active = false
local supply_items = {}

local function supply_flush()
    supply_active = false
    local body = (#supply_items > 0) and (": " .. table.concat(supply_items, ", ")) or " вскрыт"
    log("🪂 ГРУЗ ПОДДЕРЖКИ" .. body)
    supply_items = {}
end

local function supply_start()
    if supply_active then return end
    local ok = pcall(function() ExecuteWithDelay(2000, supply_flush) end)
    if ok then
        supply_active, supply_items = true, {}
    else
        log("🪂 ГРУЗ ПОДДЕРЖКИ вскрыт")                 -- нет таймера — хотя бы факт
    end
end

-- 🔓 КЛЕТКА С ЗАТОЧЁННЫМ ПАЛОМ. Просьба Олега 2026-07-27 21:07: при освобождении пала
-- В ТОТ ЖЕ МОМЕНТ выпадает фрукт привязанности (и прочий лут) — раньше клетка и фрукт
-- шли двумя событиями и перебивали друг друга. Механика та же, что у тайника/груза:
-- F по клетке -> окно, весь лут копится в буфер и уходит ОДНОЙ строкой
-- «🔓 ОСВОБОЖДЁН ПАЛ ИЗ КЛЕТКИ: фрукт привязанности, …». Одно событие вместо двух.
-- 2026-07-31 16:25: окно было 2 с — мало. По живому логу фрукт привязанности падает
-- в инвентарь стабильно через ~7 с после клетки (анимация освобождения), не сразу, и
-- при окне 2 с шёл отдельной строкой, перебивая клетку. Расширил до 8 с — фрукт
-- успевает в буфер. В буфер копятся только «ПОЛУЧЕН ПРЕДМЕТ» (AddItem), а руда/камни
-- с пола идут как [РАЗВЕДКА] мимо — длинное окно не тащит мусор, только реальный лут.
local cage_active = false
local cage_items = {}

local function cage_flush()
    if not cage_active then return end                 -- уже закрыто (лут закрыл раньше предохранителя) — no-op
    cage_active = false
    local body = (#cage_items > 0) and (": " .. table.concat(cage_items, ", ")) or ""
    log("🔓 ОСВОБОЖДЁН ПАЛ ИЗ КЛЕТКИ" .. body)
    cage_items = {}
end

local function cage_start()
    if cage_active then return end
    -- 2026-07-31 16:33: окно закрывалось по ФИКСИРОВАННОМУ таймеру (8 с), а фрукт
    -- привязанности падает через ~7-8+ с (анимация плавает) — таймер разминался с
    -- фруктом на доли секунды, клетка уходила пустой строкой, фрукт отдельной и
    -- перебивал озвучку. Теперь окно закрывает САМ лут (в хуке AddItemGetLog ниже:
    -- упал предмет → flush через 600 мс), поэтому фрукт всегда внутри строки клетки.
    -- Таймер 15 с — лишь предохранитель: если из клетки лут не выпал вовсе, закрыть
    -- окно пустой строкой, чтобы cage_active не завис навсегда.
    cage_active, cage_items = true, {}
    local ok = pcall(function() ExecuteWithDelay(15000, cage_flush) end)
    if not ok then
        cage_active = false
        log("🔓 ОСВОБОЖДЁН ПАЛ ИЗ КЛЕТКИ")               -- нет таймера — хотя бы факт
    end
end

-- 📦 ПОЛУЧЕН ПРЕДМЕТ / 💰 ДЕНЬГИ — НАДЁЖНЫЙ клиентский хук уведомления «+предмет».
-- Прошлый AddItem_ServerInternal регистрировался OK, но в ОДИНОЧНОЙ игре не вызывался
-- (это серверная функция; в синглплеере подбор идёт другим путём) — поэтому ноль событий.
-- Из дампа взяла ту функцию, что РЕАЛЬНО дёргается на клиенте — она рисует плашку
-- «получено N предмета» на экране, а значит вызывается на КАЖДЫЙ приход предмета:
--   APalPlayerState:AddItemGetLog_ToClient(FPalStaticItemIdAndNum ItemAndNum, float DelayTime)
--   struct FPalStaticItemIdAndNum { FName StaticItemId; int32 Num; }
-- Ловит подбор с земли, лут из сундука, ПОКУПКУ, ПРОДАЖУ, награду за квест, крафт.
-- Деньги в Palworld — это ПРЕДМЕТ с id "Money", поэтому этот же хук ловит и золото.
hook("/Script/Pal.PalPlayerState:AddItemGetLog_ToClient", function(self, ItemAndNum, DelayTime)
    local id, n = nil, nil
    pcall(function()
        local st = val(ItemAndNum)
        if st == nil then return end
        id = s(st.StaticItemId)
        n  = st.Num
    end)
    if not id or id == "None" or id == "" then return end
    if tainich_active or supply_active or cage_active then
        -- окно тайника/груза/клетки открыто: не логируем предмет отдельно, копим в буфер —
        -- всё уйдёт одной строкой (tainich_flush / supply_flush / cage_flush).
        local frag
        if id == "Money" then
            frag = "монеты +" .. (type(n) == "number" and n or "?")
        else
            frag = item_ru(id) .. (type(n) == "number" and n > 1 and (" x" .. n) or "")
        end
        table.insert(cage_active and cage_items or (supply_active and supply_items or tainich_items), frag)
        if cage_active then
            -- лут из клетки упал (фрукт привязанности и т.п.) — закрываем окно ОДНОЙ
            -- строкой через 600 мс (успеть дособрать соседние предметы, если их несколько),
            -- не дожидаясь 15-с предохранителя. Так строка «клетка + фрукт» уходит сразу
            -- по факту лута — без разминки по таймауту, из-за которой фрукт перебивал.
            pcall(function() ExecuteWithDelay(600, cage_flush) end)
        end
        return
    end
    if id == "Money" then
        log("💰 ДЕНЬГИ +" .. (type(n) == "number" and n or "?"))
    elseif id:lower():find("palegg") then
        -- 🥚 ПАЛ-ЯЙЦО (инкубируется). id всех инкубируемых яиц содержит "HatchingPalEgg".
        -- Из id читаем ТИП (элемент + размер = РЕДКОСТЬ): Common < Large < Huge < Giant/Mega/Boss.
        -- Точный ВИД пала внутри в момент подбора НЕ доступен: он лежит в динамических
        -- данных яйца (UPalDynamicPalEggItemDataBase.CharacterID) и раскрывается позже.
        local size = "обычное"
        local low = id:lower()
        if     low:find("giant") or low:find("mega") or low:find("boss") then size = "★ГИГАНТСКОЕ (топ-редкость)"
        elseif low:find("huge")  then size = "★ОГРОМНОЕ (редкое)"
        elseif low:find("large") then size = "большое"
        end
        log("🥚 НАЙДЕНО ЯЙЦО: " .. id .. (type(n) == "number" and (" x" .. n) or "") .. " [" .. size .. "] — пал, в инкубатор")
    elseif id:lower():find("egg") then
        -- 🍳 ПРОСТОЕ ЯЙЦО (item id "Egg", из курятника) — это ЕДА / ингредиент кулинарии,
        -- НЕ пал-яйцо и НЕ в инкубатор. Подбираем часто, поэтому не событие, а фон.
        log("🍳 ЯЙЦО (простое): " .. (type(n) == "number" and ("x" .. n .. " ") or "") .. "— в еду или кулинарию, НЕ в инкубатор")
    else
        local sf = skill_fruit_line(id)
        if sf then log(sf); return end
        if not notable_item(id) then
            if DISCOVER_ITEMS then
                log("[РАЗВЕДКА] предмет (плашка): " .. item_ru(id) .. (type(n) == "number" and (" x" .. n) or ""))
            end
            return                                 -- заглушка спама рядовых предметов
        end
        log("ПОЛУЧЕН ПРЕДМЕТ: " .. item_ru(id) .. (type(n) == "number" and (" x" .. n) or ""))
    end
end)

-- 🥚 ЯЙЦО / подбор МИР-ОБЪЕКТА. ГЛАВНЫЙ ФИКС 2026-07-23: яйцо из мира (одиночное и
-- из гнезда боссов) — это НЕ предмет-в-инвентарь, а MapObject, который ты «поднимаешь»
-- действием (RequestPickup). Такой подбор идёт ДРУГИМ путём и НЕ дёргает плашку
-- AddItemGetLog_ToClient (та ловит только лут/сундук/покупку/крафт) — вот почему яйцо
-- за весь день ни разу не залогировалось, хотя всё остальное ловилось.
-- Из CXX-дампа: клиент узнаёт об успешном подборе мир-объекта через
--   UPalNetworkMapObjectComponent:NotifyReceivePickupResultSuccess_ToClient(Archive, Model, bAll)
-- Model — живой UObject-модель (для яйца UPalMapObjectPalEggModel), у неё есть
--   GetVisualStaticItemId() -> FName (id яйца: элемент + размер = РЕДКОСТЬ). Читать безопасно.
-- Тот же хук заодно чинит «подбор с пола не показывается» — floor-пикапы идут тут же.
hook("/Script/Pal.PalNetworkMapObjectComponent:NotifyReceivePickupResultSuccess_ToClient",
function(self, Archive, Model, bAll)
    local vid = nil
    pcall(function()
        local m = val(Model)
        if m and not (m.IsValid and not m:IsValid()) then
            vid = s(m:GetVisualStaticItemId())
        end
    end)
    if not vid or vid == "None" or vid == "" then
        return                                    -- безымянный мир-объект — не сорим
    end
    if vid:lower():find("palegg") then
        local size, low = "обычное", vid:lower()
        if     low:find("giant") or low:find("mega") or low:find("boss") then size = "★ГИГАНТСКОЕ (топ-редкость)"
        elseif low:find("huge")  then size = "★ОГРОМНОЕ (редкое)"
        elseif low:find("large") then size = "большое"
        end
        log("🥚 НАЙДЕНО ЯЙЦО: " .. vid .. " [" .. size .. "] — пал, в инкубатор")
    elseif vid:lower():find("egg") then
        log("🍳 ЯЙЦО (простое) — в еду или кулинарию, НЕ в инкубатор")
    else
        local sf = skill_fruit_line(vid)
        if sf then log(sf); return end
        if not notable_item(vid) then
            if DISCOVER_ITEMS then
                log("[РАЗВЕДКА] предмет (с пола): " .. item_ru(vid))
            end
            return                                 -- заглушка спама подбора с земли
        end
        log("ПОДОБРАЛ С ПОЛА: " .. item_ru(vid))
    end
end)

-- 💰 ДЕНЬГИ — запасной трекер (ловит и ТРАТУ, чего плашка выше не показывает).
-- RequestCalcMoney() — реальный метод UPalMoneyData, дёргается при пересчёте суммы.
-- Читаем текущую (GetNowMoney) у живого объекта-данных, логируем разницу. Если в одиночке
-- не сработает — приход всё равно виден выше через плашку, лишним не будет.
-- int64 из UE4SS приходит НЕ числом, а спец-объектом — вот почему деньги молчали
-- весь день: старый guard `type(now)~="number"` резал их на КАЖДОМ вызове. Берём
-- значение через tostring -> tonumber: работает и для обычного числа, и для int64.
local function num64(x)
    if x == nil then return nil end
    if type(x) == "number" then return x end
    local n = nil
    pcall(function() n = tonumber(tostring(x)) end)
    return n
end

-- Окно торговли: пока оно открыто, изменение денег — это сделка у торговца, а не
-- случайный лут. Ставится при разговоре с торговцем и при ответе магазина (хуки ниже).
-- Нужно потому, что RequestSellItems/Pals_ToServer — СЕРВЕРНЫЕ RPC: у гостя на чужом
-- сервере они не дёргаются, и продажа была видна только как «💰 ДЕНЬГИ +N».
local TRADE_UNTIL = 0

local last_money = nil
hook("/Script/Pal.PalMoneyData:RequestCalcMoney", function(self)
    pcall(function()
        local md = val(self)
        if md == nil then return end
        local now = num64(md:GetNowMoney())
        if now == nil then return end
        if last_money == nil then
            last_money = now
            log("💰 ДЕНЬГИ (сейчас): " .. now)     -- первый замер — покажем текущую сумму
            return
        end
        if now ~= last_money then
            local d = now - last_money
            local sign = (d >= 0) and ("+" .. d) or tostring(d)
            if os.time() < TRADE_UNTIL then        -- деньги в окне торговли = сделка
                log("🛒 ТОРГОВЕЦ: " .. ((d >= 0) and ("продали, " .. sign) or ("купили, " .. sign))
                    .. " монет -> стало " .. now)
            else
                log("💰 ДЕНЬГИ " .. sign .. " -> стало " .. now)
            end
            last_money = now
        end
    end)
end)

-- 🎁 СУНДУК открыт. Два канала, потому что серверный работает только дома:
--   APalMapObjectTreasureBox:OnReceiveOpenInServer — сервер (одиночка/свой сервер);
--   UPalMapObjectTreasureBoxModel:ReceiveOpenSuccess_ClientInternal — КЛИЕНТ, долетает
--   до гостя на чужом сервере (там серверный молчал, и сундуки были не видны).
-- Общий дедуп, чтобы дома, где живы оба, не писать одно открытие дважды.
-- Металлолом vs сундук: это ОДИН класс-хук (TreasureBox), но у кучи хлама в имени
-- класса объекта есть маркер «Junk» (BP_MapObject_TreasureBox_..._Junk_C), а у обычного
-- сундука его нет (VisibleContent/AdjustFloor и т.п.). Различаем по этому маркеру.
-- В одиночке серверный канал живёт и его self — сам актор (класс с «Junk»), поэтому
-- определение срабатывает первым и точным; у гостя серверный молчит, клиентский может
-- не дать имя актора — тогда честно скажет «сундук».
local chest_last = 0
local function is_junk_box(obj)
    local junk = false
    pcall(function()
        local m = val(obj)
        if not m or not live_obj(m) then return end
        local cn = nil
        pcall(function() cn = m:GetClass():GetFName():ToString() end)
        if not (cn and string.find(cn, "Junk")) then
            pcall(function() cn = m:GetFullName() end)
        end
        if cn and string.find(cn, "Junk") then junk = true end
    end)
    return junk
end
local function chest_log(obj, where)
    local now = os.time()
    if now - chest_last < 5 then return end
    chest_last = now
    if is_junk_box(obj) then
        log("🔩 ВСКРЫТ МЕТАЛЛОЛОМ (куча хлама)")
    else
        log("🎁 ОТКРЫТ СУНДУК" .. (where and (" " .. where) or ""))
    end
end
hook("/Script/Pal.PalMapObjectTreasureBox:OnReceiveOpenInServer", function(self) chest_log(self, nil) end)
hook("/Script/Pal.PalMapObjectTreasureBoxModel:ReceiveOpenSuccess_ClientInternal", function(self)
    local grade = nil
    pcall(function()
        local m = val(self)
        if not live_obj(m) then return end
        grade = anystr(m.TreasureGradeType)
    end)
    -- в enum Grade1..Grade6 — чем выше, тем жирнее содержимое
    chest_log(self, grade and ("(" .. grade .. ")") or nil)
end)

-- 🗿 ЭФФИГИЯ / статуя (Лифманк-эффигии и прочие «статуи»). Добавлено 2026-07-25 по
-- просьбе Олега. В мире это APalLevelObjectRelic (obtainable), собираешь действием —
-- поэтому подбор шёл МИМО плашки предмета и мимо floor-пикапа, за весь день ноль строк.
-- Из CXX-дампа надёжный клиентский канал: когда реликвия засчитана игроку, дёргается
--   APalPlayerState:OnRelicNumAddedByType(EPalRelicType Type, int32 AddNum)
-- — прямо отдаёт ТИП статуи и на сколько прибавилось. Тип — enum EPalRelicType (0..12),
-- приходит числом или именем; переводим в русское название. Никаких объектов — краш неоткуда.
local RELIC_RU = {
    ["0"]="сила поимки (зелёная эффигия Лифманка)", CapturePower="сила поимки (зелёная эффигия Лифманка)",
    ["1"]="меньше голода",            HungerReduction="меньше голода",
    ["2"]="скорость плавания",        SwimSpeed="скорость плавания",
    ["3"]="медленная порча еды",      FoodDecayReduction="медленная порча еды",
    ["4"]="сила прыжка",              JumpPower="сила прыжка",
    ["5"]="скорость планера",         GliderSpeed="скорость планера",
    ["6"]="скорость лазанья",         ClimbSpeed="скорость лазанья",
    ["7"]="стойкость к статусам",     StatusAilmentResist="стойкость к статусам",
    ["8"]="меньше расход стамины",    StaminaReduction="меньше расход стамины",
    ["9"]="самонаведение сфер",       SphereHoming="самонаведение сфер",
    ["10"]="бонус опыта",             ExpBonus="бонус опыта",
    ["11"]="шанс радужной пассивки",  RainbowPassiveRate="шанс радужной пассивки",
    ["12"]="скорость бега",           MoveSpeed="скорость бега",
}
hook("/Script/Pal.PalPlayerState:OnRelicNumAddedByType", function(self, Type, AddNum)
    local t = anystr(Type)
    local n = nil
    pcall(function() n = val(AddNum) end)
    local name = t and (RELIC_RU[t] or ("тип " .. t)) or "?"
    log("🗿 СОБРАЛ ЭФФИГИЮ (статуя: " .. name .. ")" .. (type(n) == "number" and (" +" .. n) or ""))
end)

-- 🛒 ТОРГОВЛЯ. Главный НАДЁЖНЫЙ сигнал — клиентское уведомление о завершении сделки
-- (ловит и покупку, и продажу): APalPlayerState:NotifyTradeComplete_ToClient().
-- Дополнительно — RPC-функции сделки для детализации (количество/тип): если в одиночке
-- дёрнутся — увидим подробности, нет — сам факт сделки всё равно поймает Notify выше.
simple("/Script/Pal.PalPlayerState:NotifyTradeComplete_ToClient", "🛒 ТОРГОВЕЦ: сделка завершена")
hook("/Script/Pal.PalNetworkShopComponent:RequestBuyProduct_ToServer", function(self, ShopID, ProductId, BuyNum)
    local n = nil
    pcall(function() n = val(BuyNum) end)
    log("🛒 ТОРГОВЕЦ: покупка" .. (type(n) == "number" and (" x" .. n) or ""))
end)
simple("/Script/Pal.PalNetworkShopComponent:RequestSellItems_ToServer", "🛒 ТОРГОВЕЦ: продал предметы")
simple("/Script/Pal.PalNetworkShopComponent:RequestSellPals_ToServer",  "🛒 ТОРГОВЕЦ: продал палов")

-- 🐣 КУПИЛ ПАЛА у торговца палов. Добавлено 2026-07-23 по просьбе Олега.
-- Покупка ПАЛА идёт НЕ через плашку предмета (пал — не item), поэтому обычная торговля
-- его не ловила — «купил пала» нигде не всплывало. Из CXX-дампа:
--   UPalShopProductGiver_Character:OnCreatedBuyPal(FPalInstanceID CreatedPalInstanceID)
-- — вызывается, когда купленный пал СОЗДАН. self = продавец-даватель пала, у него есть
-- поле-структура ProductPalSaveParameter (FPalIndividualCharacterSaveParameter) с ПРЯМЫМИ
-- полями пала: CharacterID (вид), Level, Rank, IsRarePal, PassiveSkillList, EquipWaza.
-- Это ЖИВОЙ объект-продавец (не труп) — читать безопасно. Всё в pcall.
local function saveparam_info(sp)
    local parts = {}
    local lv, rk, rare = nil, nil, false
    pcall(function() lv = sp.Level end)
    pcall(function() rk = sp.Rank end)
    pcall(function() rare = sp.IsRarePal end)
    if type(lv) == "number" then parts[#parts + 1] = "ур." .. lv end
    if type(rk) == "number" and rk > 0 then parts[#parts + 1] = "ранг " .. rk end
    if rare then parts[#parts + 1] = "★РЕДКИЙ" end
    local skills = read_list(function() return sp.PassiveSkillList end, conv_fname)
    if #skills > 0 then parts[#parts + 1] = "пассивки: " .. table.concat(skills, ", ") end
    local waza = read_list(function() return sp.EquipWaza end, conv_waza)
    if #waza > 0 then parts[#parts + 1] = "приёмы: " .. table.concat(waza, ", ") end
    return table.concat(parts, ", ")
end

hook("/Script/Pal.PalShopProductGiver_Character:OnCreatedBuyPal", function(self)
    local species, info = nil, ""
    pcall(function()
        local giver = val(self)
        if giver == nil then return end
        local sp = giver.ProductPalSaveParameter
        if sp == nil then return end
        species = pal_ru(s(sp.CharacterID))
        info = saveparam_info(sp)
    end)
    log("🐣 КУПИЛ ПАЛА" .. (species and (": " .. species) or " (вид не прочитался)")
        .. (info ~= "" and (" [" .. info .. "]") or ""))
end)

-- 🥚 ВЫЛУПЛЕНИЕ ПАЛА из яйца (инкубатор на базе). Из CXX-дампа:
--   UPalMapObjectHatchingEggModel:OnFinishWorkInServer(UPalWorkBase* Work)
-- — вызывается, когда яйцо доработало (вылупилось). self = модель яйца, у неё есть
-- поле-структура HatchedCharacterSaveParameter (FPalIndividualCharacterSaveParameter)
-- с ПРЯМЫМИ полями вылупившегося пала: CharacterID (вид), Level, Rank, IsRarePal,
-- PassiveSkillList, EquipWaza. Это ЖИВОЙ объект-модель (не труп) — читать безопасно.
-- ВАЖНО: на OnFinishWorkInServer поле HatchedCharacterSaveParameter ещё ПУСТОЕ
-- (CharacterID=None, Level=1 по дефолту) — оно дозаполняется позже через OnRep.
-- Поэтому читаем из HatchedPalEggData (UPalDynamicPalEggItemDataBase): вид яйца
-- задан ЗАРАНЕЕ, там есть CharacterID (0x0070) и полный SaveParameter (0x0078).
local function read_cid(sp)
    local cid = nil
    pcall(function()
        local c = s(sp.CharacterID)
        -- Валидный CharacterID — простой идентификатор ("Kitsunebi_Ice", "SheepBall").
        -- Ранняя вспышка вылупления отдаёт вместо имени сырой указатель
        -- ("UObject: 000001933E333F08") — s() честно вернул tostring объекта. Он
        -- проскакивал старую проверку (не "" и не "None") и уходил модели хешем.
        -- Пускаем только [буквы/цифры/_], всё с пробелом/двоеточием/"UObject" — брак.
        if c and c ~= "None" and c:match("^[%w_]+$") then cid = c end
    end)
    return cid
end

-- OnFinishWorkInServer срабатывает на одно вылупление НЕСКОЛЬКО раз: ранняя(-ие)
-- вспышка(-и), когда поле ещё пустое (вид не читается — вместо имени сырой указатель,
-- уровня нет, но флаг ★РЕДКИЙ уже стоит), и позже — «спелая», с настоящим видом и
-- уровнем. Если каждую слать отдельно — модель видит двух палов («редкий блестящий!»
-- и следом «о, Китсунеби!»). А если пустую молча ронять (как было до 27.07 19:58) —
-- кладки, у которых имя вообще не пришло, немеют совсем (Олег поймал: вылупил два
-- яйца — тишина).
-- Решение — ДЕБАУНС: вспышки одной кладки копим в общий буфер (берём имя/уровень с
-- любой вспышки, где они есть; редкость — с любой) и эмитим ОДНОЙ строкой через 6 c
-- после ПОСЛЕДНЕЙ вспышки. Спелая вспышка с именем (приходит ~5 c спустя) успевает
-- влиться. А если имени так и не пришло — всё равно озвучиваем честно «не разобрать,
-- кто это» (Олег 27.07: «озвучивать, даже если не знает — было интересно»).
-- Оговорка: две РАЗНЫЕ кладки в одном 6-секундном окне сольются в одну реплику —
-- редкий край, важнее что немоты больше нет.
local HATCH_GEN = 0
local HATCH_BUF = nil            -- лучшее из вспышек: { species=, extras=, rare= }

local function hatch_flush(gen)
    if gen ~= HATCH_GEN then return end   -- пришла вспышка новее — решает её флаш
    local b = HATCH_BUF
    HATCH_BUF = nil
    if b == nil then return end
    local tags = {}
    if b.rare then tags[#tags + 1] = "★РЕДКИЙ" end
    if b.extras and b.extras ~= "" then tags[#tags + 1] = b.extras end
    local tail = (#tags > 0) and (" [" .. table.concat(tags, ", ") .. "]") or ""
    local body = b.species and (": " .. b.species) or " — не разобрать, кто это"
    log("🥚 ВЫЛУПИЛСЯ ПАЛ" .. body .. tail)
end

hook("/Script/Pal.PalMapObjectHatchingEggModel:OnFinishWorkInServer", function(self)
    local species, info = nil, ""
    pcall(function()
        local model = val(self)
        if model == nil then return end
        -- 1) надёжный источник — данные самого яйца
        local egg = model.HatchedPalEggData
        if egg ~= nil then
            local cid = read_cid(egg)                 -- CharacterID прямо на яйце
            if cid then species = pal_ru(cid) end
            pcall(function()
                local sp = egg.SaveParameter
                if sp ~= nil then
                    if species == nil then
                        local c2 = read_cid(sp)
                        if c2 then species = pal_ru(c2) end
                    end
                    info = saveparam_info(sp)
                end
            end)
        end
        -- 2) запасной путь — прямое поле модели (вдруг уже заполнено)
        if species == nil then
            local sp = model.HatchedCharacterSaveParameter
            if sp ~= nil then
                local c3 = read_cid(sp)
                if c3 then species = pal_ru(c3) end
                if info == "" then info = saveparam_info(sp) end
            end
        end
    end)

    local has_level = info:find("ур%.") ~= nil          -- признак «спелой» вспышки
    local is_rare   = info:find("★РЕДКИЙ") ~= nil
    local extras    = info:gsub("★РЕДКИЙ,?%s*", ""):gsub("^,%s*", ""):gsub(",%s*$", "")

    -- Копим лучшее из вспышек кладки в общий буфер.
    HATCH_BUF = HATCH_BUF or {}
    if species ~= nil then HATCH_BUF.species = species end
    if is_rare then HATCH_BUF.rare = true end
    if has_level and extras ~= "" then HATCH_BUF.extras = extras end

    -- Каждая вспышка отодвигает флаш: эмитим через 6 c тишины после последней.
    HATCH_GEN = HATCH_GEN + 1
    local gen = HATCH_GEN
    tech("🥚 вспышка вылупления (копим) species=" .. tostring(species)
        .. " level=" .. tostring(has_level) .. " rare=" .. tostring(is_rare))
    pcall(function() ExecuteWithDelay(6000, function() hatch_flush(gen) end) end)
end)

------------------------------------------------------------------------
-- 💬 РАЗГОВОР С NPC (деревни, торговцы, квестодатели). Добавлено 2026-07-26.
--
-- ПОЧЕМУ ЭТОГО НЕ БЫЛО: диалог с NPC не ловился НИКАК — ни одного хука, ни в
-- одиночке, ни на сервере. Из деревни в лог падало только то, что случалось
-- ПОСЛЕ разговора (получен предмет, деньги), а сам факт «подошёл к торговцу /
-- заговорил с жителем» не existed. На чужом сервере это заметнее: там даже
-- торговые RPC не долетают, и деревня для Мии становится немой.
--
-- ⚠ КРАШ 2026-07-26 12:16 (EXCEPTION_ACCESS_VIOLATION reading 0x10, стек внутри
-- UE4SS-колбэка). 0x10 — смещение ClassPrivate в UObjectBase, то есть GetClass()
-- дёрнули на битом указателе. Виновник — мультикаст APalCharacter:
-- ChangeTalkModeFlag_ToAll: он стреляет по КАЖДОМУ персонажу мира, включая чужих
-- и уже уничтоженных, а pcall от нативного access violation не спасает.
-- Хук СНЯТ (за сессию он не дал ни одного имени — только вред).
-- Остался один канал: клиентский RequestStartTalkFlow — он стреляет ровно на
-- ТВОЙ разговор, объект в этот момент заведомо жив.
------------------------------------------------------------------------
local TALK_LAST = {}          -- ключ -> время последней записи (дедуп двух каналов)

local function talk_dedup(key)
    local now = os.time()
    local prev = TALK_LAST[key]
    TALK_LAST[key] = now
    return prev ~= nil and (now - prev) < 8      -- true = уже писали, молчим
end

-- BP_NPC_Shop_Item_01_C -> «торговец». Роль по имени класса, без словаря.
local function npc_role(cls)
    local c = string.lower(cls or "")
    -- Башенные боссы-NPC: разговор ПЕРЕД боем в башне. Игра отдаёт класс вида
    -- PalTalkableLevelObject_GrassBoss01 — модель читала его как «Гросс Босс 01».
    -- Возвращаем человеческое имя (то же, что в TOWER_BOSSES). Не гадаем —
    -- только известные: GrassBoss = Зоя (первая башня, Rayne Syndicate).
    -- Новые башни допишем, когда встретим их класс в tech.log. Добавлено 27.07.2026.
    if c:find("grassboss") then return "Зоя" end
    -- реальные имена из лога 26.07: NPC_SalesPerson, NPC_PalDisplay_A, NPC_Reward_BossDefeat
    if c:find("shop") or c:find("vender") or c:find("vendor") or c:find("merchant")
            or c:find("sales") or c:find("trader") or c:find("paldisplay") then
        if c:find("pal") then return "торговец палами" end
        return "торговец"
    end
    if c:find("reward") then return "выдаёт награду" end
    if c:find("wander") or c:find("caravan") then return "странствующий торговец" end
    if c:find("guard") or c:find("police") then return "охранник/патруль" end
    if c:find("quest") then return "квестодатель" end
    if c:find("farmer") then return "фермер" end
    if c:find("soldier") or c:find("army") then return "солдат" end
    if c:find("villager") or c:find("citizen") then return "житель" end
    if c:find("hunter") then return "охотник" end
    return nil
end

-- Единственный канал: клиентский старт диалогового флоу. Стреляет ровно на ТВОЙ
-- разговор (не на чужие NPC по всему миру), собеседника достаём здесь же:
-- self = компонент NPC, его владелец (GetOwner) и есть сам собеседник.
hook("/Script/Pal.PalNPCTalkFlowComponent:RequestStartTalkFlow", function(self)
    if talk_dedup("*") then return end
    local cls = nil
    pcall(function()
        local comp = val(self)
        if not live_obj(comp) then return end
        local owner = nil
        pcall(function() owner = comp:GetOwner() end)
        if owner == nil then pcall(function() owner = comp.Owner end) end
        if not live_obj(owner) then return end
        cls = pretty(owner:GetClass():GetFName():ToString())
    end)
    if cls == nil then
        log("💬 РАЗГОВОР С: (собеседник не прочитался)")
        return
    end
    TALK_LAST[cls] = os.time()
    local role = npc_role(cls)
    if role and role:find("торговец") then TRADE_UNTIL = os.time() + 120 end
    -- Роль — простым словом (торговец/фермер/солдат/житель). Латинский код класса
    -- держим в квадратных скобках как СЛУЖЕБНУЮ пометку: промпт велит модели не
    -- произносить ни его, ни слово «NPC», а звать собеседника по-человечески.
    log("💬 РАЗГОВОР С: " .. (role and (role .. " [" .. cls .. "]") or ("[" .. cls .. "]")))
end)

-- 🛒 РЕЗУЛЬТАТ ПОКУПКИ — клиентский колбэк, работает у ГОСТЯ на чужом сервере.
-- Из дампа: UPalNetworkShopComponent:RecieveBuyResult_ToClient(EPalShopBuyResultType).
-- Парные RequestBuy/Sell_ToServer — серверные RPC: за всё время работы мода они не
-- дали ни одной строки, поэтому нужен именно клиентский канал.
hook("/Script/Pal.PalNetworkShopComponent:RecieveBuyResult_ToClient", function(self, resultType)
    local r = anystr(resultType)
    TRADE_UNTIL = os.time() + 120        -- мы точно у прилавка: деньги теперь = сделка
    log("🛒 ТОРГОВЕЦ: покупка прошла" .. (r and (" (код " .. r .. ")") or ""))
end)

------------------------------------------------------------------------
-- 🗿 СТАТУИ ТЕЛЕПОРТА (просьба Олега 26.07 12:34). Раньше не ловилось никак —
-- хуков не было вообще. В дампе это ДВА разных события:
--   1) РАЗБЛОКИРОВКА статуи (первое касание): бонусный опыт + открывается кусок
--      карты. UPalNetworkPlayerComponent:RequestUnlockFastTravelPoint_ToServer(FName)
--      — клиент→сервер, то есть вызывается НА КЛИЕНТЕ, у гостя тоже стреляет.
--   2) САМ ПЕРЕНОС: UPalSyncTeleportComponent:SyncTeleport_ToClient /
--      ReceiveSyncTeleportMoveResult_ToClient — КЛИЕНТСКИЕ RPC, работают у гостя
--      на чужом сервере. Тем же каналом идёт возврат к Палбоксу и после смерти,
--      поэтому «через статую» помечаем по RequestFastTravel_ToServer (тоже клиентский).
-- Объекты здесь НЕ разыменовываем вообще: после краша 12:16 читаем только POD-
-- параметры (FName, bool). GetClass() нет ни одного — падать нечему.
------------------------------------------------------------------------
local FT_INTENT = 0        -- когда Олег ткнул точку быстрого перемещения
local TP_LAST   = 0        -- дедуп: у телепорта несколько стадий (start/move/end)

hook("/Script/Pal.PalNetworkPlayerComponent:RequestUnlockFastTravelPoint_ToServer", function(self, key)
    -- GUID точки (key) — внутренний ключ, человеческого имени места игра не отдаёт.
    -- Модели он не нужен (иначе озвучит хеш), пишем только факт. Сам ключ — в tech.log.
    tech("🗿 UnlockFastTravel key=" .. (anystr(key) or "nil"))
    log("🗿 ОТКРЫТА НОВАЯ СТАТУЯ ТЕЛЕПОРТА")
end)

hook("/Script/Pal.PalPlayerController:RequestFastTravel_ToServer", function()
    FT_INTENT = os.time()          -- GUID точки не читаем, нужен только сам факт выбора
end)

local function teleported()
    local now = os.time()
    if now - TP_LAST < 8 then return end        -- одна телепортация = одна строка
    -- 🏛 Телепорт-в-арену на входе в башню и телепорт-наружу после победы — это часть
    -- «боя в башне», а не самостоятельное перемещение. Глушим, чтобы не перебивал
    -- реплику про башню (просьба Олега 27.07: вход в башню не должен дробиться).
    if now - tower_fight_t      <= 15 then return end   -- вход в башню (арена)
    if now - last_boss_result_t <= 15 then return end   -- выход после победы
    TP_LAST = now
    local via = (now - FT_INTENT <= 20) and " через статую (быстрое перемещение)" or ""
    log("🌀 ТЕЛЕПОРТАЦИЯ" .. via)
end

hook("/Script/Pal.PalSyncTeleportComponent:SyncTeleport_ToClient", function() teleported() end)
hook("/Script/Pal.PalSyncTeleportComponent:ReceiveSyncTeleportMoveResult_ToClient", function(self, okFlag)
    if anystr(okFlag) == "false" then return end     -- перенос не удался — молчим
    teleported()
end)

------------------------------------------------------------------------
-- 🌍 ЗАХОД В МИР / СМЕНА СЕРВЕРА (просьба Олега 26.07).
-- Он прыгает по чужим серверам, ища место, а лог этого не показывал — и Мия
-- тащила в разговор палов и деньги с прошлого сервера (спрашивала про Маммареста,
-- которого уже нет). Плюс счётчики уровня/денег/очков оставались от старого мира
-- и «прыгали назад».
-- Ловим появление нового GameState — он создаётся ровно один раз на заход в мир.
-- ClientRestart для этого не годится: он дёргается на каждую посадку на пала.
------------------------------------------------------------------------
local world_last = 0
local ok_world = pcall(function()
    NotifyOnNewObject("/Script/Pal.PalGameStateInGame", function()
        local now = os.time()
        if now - world_last < 10 then return end     -- дедуп на всякий случай
        world_last = now
        last_money, tech_pts, boss_pts = nil, nil, nil   -- счётчики нового мира с нуля
        TRADE_UNTIL = 0
        TALK_LAST = {}
        log("🌍 ЗАХОД В МИР: загрузился мир — свой одиночный или сервер, новый или старый")
    end)
end)
log((ok_world and "хук OK   -> " or "хук FAIL -> ") .. "NotifyOnNewObject(PalGameStateInGame)")

------------------------------------------------------------------------
-- 🔎 РАЗВЕДКА F-ВЗАИМОДЕЙСТВИЯ (ВРЕМЕННО, 2026-07-27, просьба Олега про
-- башни-тайники). Эти башенки — НЕ сундук (TreasureBox), а свой тип объекта:
-- открыл дверь / решил головоломку, зашёл, нажал F — взял монеты + чертёж.
-- Награда уже ловится вслепую (плашка предмета), а сам факт «открыл башню» —
-- нет, потому что класс объекта неизвестен, а гадать нельзя (Down/Up, Rare).
-- Поэтому: когда жмёшь F на ЛЮБОМ объекте — пишем в tech.log РЕАЛЬНЫЙ класс
-- цели и её читаемое имя. Модель этого НЕ видит. Как увидим класс башни —
-- повесим на него честное «🏛 открыт тайник» и эту разведку снимем.
--
-- Канал: UPalInteractComponent (компонент на игроке). StartTriggerInteract —
-- реальная функция нажатия F (не делегат), цель лежит в поле
-- TargetInteractiveObject (TScriptInterface). Разворачиваем интерфейс в UObject
-- (сам объект или через :Self()), класс читаем только у живого (урок краша 12:16).
------------------------------------------------------------------------
local diag_key, diag_t = nil, 0
local note_t = 0   -- дедуп записки (Олег часто жмёт F дважды по одному объекту)
local goddess_t = 0   -- дедуп статуи улучшения характеристик (алтарь богини)
local tower_enter_t = 0  -- дедуп события «вход в башню-босса» (F по башне может дёрнуться дважды)
local expedition_t = 0  -- дедуп экспедиционного верстака (Олег тыкает F по нему несколько раз, выбирая экспедицию)
-- ⚠️ 2026-07-27: BP_InteractableCapsule_C — НЕ записка. Повесила «📜 записку» на этот
-- класс по ОДНОМУ наблюдению 11:11 и села в лужу: по факту этот класс даёт палбокс/
-- капсула, которую Олег юзает много раз подряд, а настоящая записка через этот хук
-- вообще не проходит. Событие снято — класс уходит ТОЛЬКО в tech.log (разведка ниже),
-- пока чистыми тестами не разведём, что есть что. Не гадать (урок Down/Up, Rare).
local function diag_interact_target(target, actstr)
    if target == nil then return end
    -- развернуть TScriptInterface в UObject: либо сам объект умеет GetClass,
    -- либо достаём подлежащий объект методом интерфейса Self()
    local obj = nil
    if type(target) == "userdata" and type(target.GetClass) == "function" then
        obj = target
    else
        pcall(function() obj = target:Self() end)
    end
    local cls, name = nil, nil
    if live_obj(obj) then
        pcall(function() cls = obj:GetClass():GetFName():ToString() end)
    end
    pcall(function() name = s(target:GetInteractTargetName()) end)
    if not (name == nil or name == "") then name = name else name = nil end
    -- ⚠️ 2026-07-27 12:57: BP_InteractableBox_C — НЕ только башня-тайник. Оказалось,
    -- этот же класс даёт ВЕРСТАК/мастерская: Олег заходит в любой верстак — мод орёт
    -- «тайник». Классика «вывод на одном сэмпле» (как записка/capsule). Слепой триггер
    -- «тайник» СНЯТ — иначе врёт на каждый верстак. Пока копим разведку: класс у башни
    -- и у верстака один, ищем чем отличаются (полное имя / владелец). Не гадать (Down/Up).
    -- 2026-07-27 13:04: клетка с заточённым палом дала класс
    -- PalInteractableSphereComponentNative — ТОТ ЖЕ, что у статуй усиления. По классу
    -- клетку от статуи не различить (как верстак/тайник). Поэтому добор full/outer теперь
    -- пишем для ЛЮБОГО живого объекта, а не только для BOX — чтобы найти, чем клетка
    -- отличается от статуи усиления. Не гадать (урок Down/Up, Rare).
    local extra = ""
    if live_obj(obj) then
        local full, outer = nil, nil
        pcall(function() full = obj:GetFullName() end)
        pcall(function() outer = obj:GetOuter():GetClass():GetFName():ToString() end)
        extra = "  [full=" .. tostring(full) .. " outer=" .. tostring(outer) .. "]"
        -- 📜 ЗАПИСКА. 2026-07-27 13:09 разведка дала: настоящая записка = общий класс
        -- PalInteractableSphereComponentNative (как у статуй/клетки), НО outer =
        -- BP_LevelObject_Note_C. По классу не различить, по outer — железно. Вешаем на
        -- outer, а не на класс (урок верстак/тайник). Сам текст записки этот канал не даёт
        -- (имя=nil) — только факт; лор читается через F8/зрение.
        if outer == "BP_LevelObject_Note_C" then
            local nnow = os.time()
            if (nnow - note_t) >= 3 then
                note_t = nnow
                log("📜 НАЙДЕНА ЗАПИСКА")
            end
        end
        -- 🔓 КЛЕТКА С ЗАТОЧЁННЫМ ПАЛОМ. 2026-07-27 13:42 разведка на реальной клетке дала:
        -- класс общий (сфера PalInteractableSphereComponentNative, как у статуй/записок), НО
        -- outer = BP_PalCapturedCage_C. По классу не различить, по outer — железно. Вешаем на
        -- outer (урок верстак/тайник). Лут (что было в клетке) сыпется своими строками.
        if outer == "BP_PalCapturedCage_C" then
            -- 2026-07-27 21:07: раньше тут был мгновенный log — и выпадающий чуть погодя
            -- фрукт привязанности шёл ОТДЕЛЬНЫМ событием, перебивая клетку. Теперь окно 8 с
            -- (cage_start): лут копится в буфер и уходит одной строкой с клеткой. Само окно
            -- (cage_active) защищает от повторного старта, отдельный дедуп cage_t не нужен.
            cage_start()
        end
        -- 🏛 ТАЙНИК-БАШНЯ. 2026-07-27 13:16 разведка на РЕАЛЬНОЙ башне (взлом секретом →
        -- активация → подбор) дала: класс общий (сфера), но outer =
        -- BP_LevelObject_ItemPickupTower_C. ЭТО и есть та башенка, что весь день путали с
        -- верстаком: BP_InteractableBox_C оказался ВЕРСТАКОМ, а не тайником. Вешаем окно
        -- сбора награды (tainich_start) на настоящий outer — награда (чертёж, монеты)
        -- уйдёт одной строкой «🏛 ОТКРЫТ ТАЙНИК: …». Обычные сундуки (TreasureBox) ловятся
        -- своим хуком выше — их не трогаем.
        if outer == "BP_LevelObject_ItemPickupTower_C" then
            tainich_start()
        end
        -- 🪂 ГРУЗ ПОДДЕРЖКИ. 2026-07-27 13:30 разведка на реальном грузе дала: класс общий
        -- BP_InteractableBox_C, но outer = BP_MapObject_SupplyDrop_C. Вешаем окно сбора на
        -- этот outer — уйдёт одной строкой «🪂 ГРУЗ ПОДДЕРЖКИ: …» (или просто «вскрыт»).
        if outer == "BP_MapObject_SupplyDrop_C" then
            supply_start()
        end
        -- ⚜️ СТАТУЯ УЛУЧШЕНИЯ (алтарь богини). 2026-07-27 14:04 разведка дала: класс общий
        -- BP_InteractableCapsule_C (как палбокс — на нём я утром села в лужу), НО outer =
        -- BP_LevelObject_GoddessStatue_C. По классу не различить, по outer — железно. Вешаем
        -- на outer (урок верстак/тайник). «Свою/чужую» этот канал НЕ различает (outer один,
        -- отличается только UAID) — событие про факт «решил улучшиться», без владельца.
        -- 2026-07-27 19:24: домашняя (построенная игроком) статуя богини — тот же алтарь
        -- улучшения, но outer = BP_BuildObject_BuildableGoddessStatue_C (префикс BP_BuildObject_
        -- = постройка игрока). Дикая на карте = BP_LevelObject_GoddessStatue_C. Функция одна —
        -- ловим оба на одно событие.
        if outer == "BP_LevelObject_GoddessStatue_C" or outer == "BP_BuildObject_BuildableGoddessStatue_C" then
            local gnow = os.time()
            if (gnow - goddess_t) >= 3 then
                goddess_t = gnow
                log("⚜️ СТАТУЯ УЛУЧШЕНИЯ (можно поднять характеристики / раскидать баллы)")
            end
        end
        -- 🧭 ЭКСПЕДИЦИЯ (экспедиционный верстак). Просьба Олега 2026-07-27 22:44: поставил
        -- верстак и отправил палов в экспедицию — повесить событие. Разведка (tech.log,
        -- 22:33/22:35/22:36) дала: класс общий BP_InteractableBox_C (как верстак/печь — сам по
        -- себе в ленту не идёт), НО outer = BP_BuildObject_Expedition_C. По outer — железно.
        -- Дедуп 15 с: Олег жмёт F по верстаку несколько раз, пока выбирает экспедицию.
        if outer == "BP_BuildObject_Expedition_C" then
            local enow = os.time()
            if (enow - expedition_t) >= 15 then
                expedition_t = enow
                log("🧭 ЭКСПЕДИЦИЯ (отправляешь палов на задание за наградой)")
            end
        end
        -- 🏛 БАШНЯ-БОСС (UAID → имя босса). 2026-07-27: имя из боя не достать (краш),
        -- обходим через постоянный отпечаток башни. F по башне ловит вход — объект башни
        -- ЖИВОЙ, читать безопасно. Достаём UAID-ключ из full, запоминаем; при победе
        -- (boss_finish) подставим имя из TOWER_BOSSES. Ключ = hex-часть UAID (суффикс _NNN
        -- срезаем — он instance-id, hex стабилен для конкретной башни). Не гадаем: чего
        -- нет в таблице — падает в tech.log, заполняем руками по имени с экрана.
        if outer == "BP_PalBossTower_C" then
            local key = full and full:match("BP_PalBossTower_C_UAID_(%w+)") or nil
            if key then
                pending_tower_key = key
                pending_tower_t = os.time()
                tower_fight_t = os.time()   -- метка на КАЖДОЕ F по башне: глушит телепорт-в-арену и «бой начался»
                tech("🏛 ВХОД В БАШНЮ-БОССА  ключ=" .. key
                    .. "  босс=" .. (TOWER_BOSSES[key] or "НЕИЗВЕСТЕН (впиши в TOWER_BOSSES)"))
                -- СОБЫТИЕ МОДЕЛИ СРАЗУ НА ВХОДЕ (просьба Олега 2026-07-27): пока идёт долгая
                -- заставка боя — пусть уже говорит, на кого идём. Имя берём из паспорта башни
                -- (TOWER_BOSSES) тем же UAID-ключом, что и победа. Есть имя — называем; нет —
                -- просто «впереди бой с башенным боссом». Дедуп 60 с: Олег жмёт F несколько
                -- раз (первое нажатие «ничего не делает»), промежутки бывают 13+ с — 5 с не
                -- ловил, шло двойное «впереди бой». 60 с = одна башня = одно объявление.
                -- Текст содержит «БОСС» → классификатор (brain.py) ловит его как событие, не спам.
                local tnow = os.time()
                if (tnow - tower_enter_t) >= 60 then
                    tower_enter_t = tnow
                    local nm = TOWER_BOSSES[key]
                    if nm then
                        log("★БОСС: впереди бой в башне — " .. nm)
                    else
                        log("★БОСС: впереди бой с башенным боссом")
                    end
                end
            end
        end
    end
    if cls == nil and name == nil then return end
    local key = tostring(cls) .. "|" .. tostring(name)
    local now = os.time()
    if key == diag_key and (now - diag_t) < 2 then return end   -- дребезг одного нажатия
    diag_key, diag_t = key, now
    local tail = ""
    if actstr and actstr ~= "" then tail = "  действие=" .. actstr end
    tech("🔎 F-ВЗАИМОДЕЙСТВИЕ: класс=" .. tostring(cls) .. "  имя=" .. tostring(name) .. tail .. extra)
end

hook("/Script/Pal.PalInteractComponent:StartTriggerInteract", function(self, ActionType, IsToggle)
    pcall(function()
        local comp = val(self)
        if comp == nil then return end
        diag_interact_target(comp.TargetInteractiveObject, anystr(ActionType))
    end)
end)

-- Запасной канал: старт взаимодействия отдаёт объект ПРЯМЫМ параметром (на случай,
-- если поле TargetInteractiveObject окажется пустым в момент нажатия).
hook("/Script/Pal.PalInteractComponent:StartInteractiveObjectDelegate", function(self, InteractiveObject)
    pcall(function()
        diag_interact_target(val(InteractiveObject), nil)
    end)
end)

------------------------------------------------------------------------
-- 🗺 ПЕРЕХОД ИЗ ОБЛАСТИ В ОБЛАСТЬ (просьба Олега 2026-07-30, версия 2 — крашбезопасная).
-- Механизм тот же, что уже сработал в логе: объёмы-триггеры регионов зовут на КЛИЕНТЕ
-- реальную UFunction OnOverlap(OtherActor) — у неё есть self.AreaName.Key = код области.
-- (Делегат OnChangeRegionAreaDelegate не берём — сигнатура мультикаста, RegisterHook
-- её не цепляет, как и 14 мёртвых OnXxxDelegate.)
--
-- ПОЧЕМУ УРОНИЛО ИГРУ В ПРОШЛЫЙ РАЗ и как лечим:
--   1) overlap стреляет В МОМЕНТ спавна (персонаж появляется уже внутри объёма) —
--      чтение полей полусозданной пешки = нативный краш, pcall его НЕ ловит.
--      Лечим замком world_ready: первые 10 сек после загрузки мира хук молчит.
--   2) слабая проверка `who.IsValid and not who:IsValid()` пропускала битый указатель,
--      и GetClass() валил игру. Лечим строгим live_obj() ПЕРЕД любым чтением.
local region_cur, region_t = nil, 0

local function region_entered(self, OtherActor)
    if not world_ready then return end          -- замок: молчим весь спавн-всплеск
    pcall(function()
        -- вошёл именно мой персонаж (не пал, не чужой игрок)
        local who = val(OtherActor)
        if not live_obj(who) then return end     -- строгая проверка, не goto crash
        local cls = nil
        pcall(function() cls = who:GetClass():GetFName():ToString() end)
        if not (cls and cls:find("PlayerCharacter")) then return end
        local mine = false
        pcall(function() mine = who:IsLocallyControlled() end)
        if not mine then return end

        local trig = val(self)
        if not live_obj(trig) then return end
        local key = nil
        pcall(function() key = s(trig.AreaName.Key) end)
        if not key or key == "" or key == "None" then return end

        local now = os.time()
        if key == region_cur and now - region_t < 30 then return end   -- та же область
        region_cur, region_t = key, now

        local ru = REGIONS_RU[key]
        if ru then
            log("🗺 НОВАЯ ОБЛАСТЬ: " .. ru)
        else
            tech("🗺 region key=" .. key)         -- сырьё для словаря regions_ru.lua
        end
    end)
end

hook("/Script/Pal.PalRegionAreaTriggerBase:OnOverlap", region_entered)
