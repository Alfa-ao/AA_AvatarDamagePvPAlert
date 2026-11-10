--------------------------------------------------------------------------------
--[[
DnDManager.lua - Менеджер Drag&Drop и Resize для виджетов.

Класс DnDManager реализует следующие методы:
    self.Init
    self.Register             - Регистрация виджета с его дополнительными настройками.
    self.Unregister           - Удаление виджета из менеджера.
    self.SetEnabled           - Включение/отключение возможности перетаскивания.
    self.AllocateDnDID        - Генерация уникального DnD ID для виджета.
    self.GetWidgetID          - Поиск dndId по любому из связанных виджетов.
    self.IsDragActive         - Проверка наличия активного перетаскивания.
    self.UnregisterAllEvents  - Полная дерегистрация всех событий.
    self.UpdateSavedPlacement - Нужен после программного изменения размера виджета извне.
]]
--------------------------------------------------------------------------------

Class( "DnDManager", {
    __CONFIG_VERSION = "1.0.0-original",
    _widgets = {}, -- Хранилище зарегистрированных виджетов [ dndId ] = WidgetInfo
    _activeDrag = nil, -- Текущее состояние активного перетаскивания
    _eventHandlers = nil, -- Ссылки на коллбэки для отписки от событий
    _screenParams = nil, -- Кэш параметров окна игры
} )

local _assert = assert
local assert = function( is, fmt, ... )
    _assert( is, string.format( fmt, ... ) )
end

--------------------------------------------------------------------------------
--- Для Resize. Вызов callback
--- @param cb function|table Callback функция или таблица {instance, method}
--- @param wtMovable userdata|table Виджет для передачи в callback
--------------------------------------------------------------------------------
local function InvokeCallback( cb, wtMovable )
    if type( cb ) == "function" then
        cb( wtMovable )
    elseif type( cb ) == "table" and type( cb[1] ) == "table" and type( cb[2] ) == "function" then
        cb[2]( cb[1], wtMovable )
    end
end

--------------------------------------------------------------------------------
--- @param wtWidget userdata|table Виджет
--- @return string name имя ключа для конфига
--------------------------------------------------------------------------------
local function GetWidgetTreePath( wtWidget )
    local components = {}
    while wtWidget do
        table.insert( components, 1, wtWidget:GetName() )
        wtWidget = wtWidget:GetParent()
    end
    
    return table.concat( components, '.' )
end

--------------------------------------------------------------------------------
--- @param widget userdata|table Виджет Widget или TWidget
--- @return boolean isWidget True, если объект является виджетом
--------------------------------------------------------------------------------
local function IsWidget( widget )
    if widget == nil then return false end

    if common.IsWidget( widget ) then return true end
    
    if type( widget ) ~= "table" or type( rawget( _G, "IsTWidget" ) ) ~= "function" then
        return false
    end
    
    -- WidgetCoreUserMods.lua
    local meta = getmetatable( widget )
    if not meta then
        return false
    end
    
    local _id = rawget( meta, "id" )
    local _widget = rawget( meta, "widget" )
    
    if _id and _widget and common.IsWidget( _widget ) then
        return GetTWidgetById( _id ) == widget
    end

    return false
end

--------------------------------------------------------------------------------
--- Инициализация менеджера.
--- @param params table|nil
--------------------------------------------------------------------------------
function DnDManager:Init( params )
    params = type( params ) == "table" and params or {}
    
    self._screenParams = common.GetPosConverterParams()
    self._options = {
        defaultCursor = type( params.defaultCursor ) == "string"
            and params.defaultCursor or "default",
    }
    
    if type( params.configProvider ) == "table" then
        assert(
            type( params.configProvider.get ) == "function",
            "configProvider.get must be a function"
        )

        assert(
            type( params.configProvider.set ) == "function",
            "configProvider.set must be a function"
        )

        self._options.configProvider = params.configProvider
    else
        self._options.configProvider = {
            get = function()
                return userMods.GetGlobalConfigSection( common.GetAddonName() ) -- table|nil
            end,

            set = function( section )
                userMods.SetGlobalConfigSection( common.GetAddonName(), section )
            end,
        }
    end
    
    self:_RegisterAllEvents()
end

--------------------------------------------------------------------------------
--- @class DndResizeHandleLimits
--- @field min number|nil Минимальный допустимый размер.
--- @field max number|nil Максимальный допустимый размер.

--- @class DndResizeHandleOptions
--- @field wtHandle userdata|table Маркер для растягивания.
--- @field allowX boolean Разрешить изменение размера по X.
--- @field allowY boolean Разрешить изменение размера по Y.
--- @field limitsX DndResizeHandleLimits|nil Допустимые размеры по X.
--- @field limitsY DndResizeHandleLimits|nil Допустимые размеры по Y.
--- @field callback function|table|nil Функция или таблица {instance, method}.

--- @class DndRegisterOptions
--- @field wtReacting userdata|table|nil Виджет, на котором реагирует DnD.
--- @field saveToConfig boolean|nil Использовать конфиг для сохранения позиции.
--- @field lockedToParentArea boolean|nil Ограничивать ли перемещение областью родителя.
--- @field kbFlag number|nil Флаг клавиш KBF_*.
--- @field cursor string|nil Курсор во время перетаскивания.

--- Регистрация виджета с его дополнительными настройками и маркеры изменения размера.
--- @param wtMovable userdata|table Перемещаемый виджет.
--- @param options DndRegisterOptions|nil Настройки регистрации.
--- @param resizeHandles DndResizeHandleOptions[]|nil Таблица маркеров для растягивания.
--- @return number dndId ID зарегистрированного виджета.
--------------------------------------------------------------------------------
function DnDManager:Register( wtMovable, options, resizeHandles )
    options = type( options ) == "table" and options or {}
    
    self:_ValidateWidget( wtMovable, "wtMovable" )
    
    if options.wtReacting ~= nil then
        self:_ValidateWidget( options.wtReacting, "wtReacting" )
    else
        options.wtReacting = wtMovable
    end

    local dndId = self:AllocateDnDID( options.wtReacting )
    
    assert( not self._widgets[ dndId ], "DnDManager:Register() failed: widget is already registered, dndId = %s", dndId )
    assert( 
        options.wtReacting:DNDGetState() == DND_STATE_NOT_REGISTERED,
        "DnDManager:Register() failed: widget is already registered in DND system outside manager, dndId = %s, state = %s",
        dndId, options.wtReacting:DNDGetState()
    )
    
    options.wtReacting:DNDRegister( dndId, true )
    options.cursor = type( options.cursor ) == "string"
            and options.cursor or self._options.defaultCursor

    local info = {
        dndId = dndId,
        wtMovable = wtMovable,
        wtReacting = options.wtReacting,
        enabled = true,
        saveToConfig = options.saveToConfig == true, -- По умолчанию false.
        lockedToParentArea = options.lockedToParentArea ~= false, -- По умолчанию true.
        kbFlag = type( options.kbFlag ) == "number" and options.kbFlag or false, -- По умолчанию false. Ограничения отключены.
        cursor = options.cursor, -- По умолчанию "default". Имена в нижнем регистре.
    }

    if info.saveToConfig then
        info.configName = "DnD:" .. GetWidgetTreePath( wtMovable ) -- DnD:Main.Panel
        self:_LoadConfig( info )
    end
    
    info.savedPlacement = wtMovable:GetPlacementPlain()
    
    self._widgets[ dndId ] = info
    
    if type( resizeHandles ) == "table" then
        assert( #resizeHandles <= 8, "DnDManager: Resize handles limit exceeded. Maximum 8, %d provided.", #resizeHandles )
        
        for _, handleData in ipairs( resizeHandles ) do
            self:_RegisterResizeHandle(
                handleData.wtHandle,
                handleData.allowX, handleData.allowY,
                handleData.limitsX, handleData.limitsY,
                handleData.callback,
                info
            )
        end
    end
    
    return dndId
end

--------------------------------------------------------------------------------
--- Регистрация маркера для изменения размера основного виджета
--- @param wtHandle userdata|table Маркер для растягивания
--- @param allowX boolean Разрешить изменение размера по X
--- @param allowY boolean Разрешить изменение размера по Y
--- @param limitsX table|nil Допустимые размеры по X { min = number, max = number }
--- @param limitsY table|nil Допустимые размеры по Y { min = number, max = number }
--- @param callback function|table|nil Функция или таблица с функцией обратного вызова после изменения размера
--- @param baseInfo table Информация об основном виджете для настроек
--------------------------------------------------------------------------------
function DnDManager:_RegisterResizeHandle( wtHandle, allowX, allowY, limitsX, limitsY, callback, baseInfo )
    limitsX = type( limitsX ) == "table" and limitsX or {}
    limitsY = type( limitsY ) == "table" and limitsY or {}
    
    self:_ValidateWidget( wtHandle, "wtHandle" )
    
    local dndId = self:AllocateDnDID( wtHandle )
    local handlePlc = wtHandle:GetPlacementPlain()
    
    assert( self._widgets[ dndId ] == nil, "DnDManager: handle is already registered, dndId = %s", dndId )
    assert( wtHandle:DNDGetState() == DND_STATE_NOT_REGISTERED, "DnDManager: handle already registered in DND system" )
    
    wtHandle:DNDRegister( dndId, true )
    
    if handlePlc.alignX == WIDGET_ALIGN_CENTER then
        allowX = false
    end
    
    if handlePlc.alignY == WIDGET_ALIGN_CENTER then
        allowY = false
    end
    
    self._widgets[ dndId ] = {
        dndId = dndId,
        wtMovable = baseInfo.wtMovable,
        wtReacting = wtHandle,
        enabled = true,
        saveToConfig = baseInfo.saveToConfig,
        lockedToParentArea = baseInfo.lockedToParentArea,
        kbFlag = baseInfo.kbFlag,
        cursor = baseInfo.cursor,
        configName = baseInfo.configName,
        isResize = true,
        resizeX = allowX == true,
        resizeY = allowY == true,
        resizeCallback = callback,
        limitsX = {
            min = limitsX.min or 50,
            max = limitsX.max or 900,
        },
        limitsY = {
            min = limitsY.min or 50,
            max = limitsY.max or 500,
        },
    }
end

--------------------------------------------------------------------------------
--- @param wtWidget userdata|table Виджет
--------------------------------------------------------------------------------
function DnDManager:Unregister( wtWidget )
    self:_ValidateWidget( wtWidget, "wtWidget" )

    local dndId = self:GetWidgetID( wtWidget )
    if not dndId then return end

    local info = self._widgets[ dndId ]
    if not info then return end
    
    if self:IsDragActive() and self._activeDrag.info.dndId == dndId then
        if info.wtReacting:DNDGetState() ~= DND_STATE_NOT_REGISTERED then
            info.wtReacting:DNDCancelDrag()
        end

        self:_StopDragging( false )
    end

    if info.wtReacting:DNDGetState() ~= DND_STATE_NOT_REGISTERED then
        info.wtReacting:DNDUnregister()
    end

    self._widgets[ dndId ] = nil
end

--------------------------------------------------------------------------------
--- @param wtWidget userdata|table Сам виджет
--- @param isEnabled boolean Включение/Выключение перетаскивание
--------------------------------------------------------------------------------
function DnDManager:SetEnabled( wtWidget, isEnabled )
    self:_ValidateWidget( wtWidget, "wtWidget" )

    local dndId = self:GetWidgetID( wtWidget )
    assert( dndId ~= nil, "DnDManager:SetEnabled() failed: widget is not registered" )
    
    local info = self._widgets[ dndId ]
    isEnabled = isEnabled == true
    
    if not isEnabled and self:IsDragActive() and self._activeDrag.info.dndId == dndId then
        info.wtReacting:DNDCancelDrag()
        self:_StopDragging( false )
    end
    
    info.enabled = isEnabled
    info.wtReacting:DNDEnable( isEnabled )
end

--------------------------------------------------------------------------------
--- @param wtWidget userdata|table Виджет
--- @return number dndId Уникальный идентификатор
--------------------------------------------------------------------------------
function DnDManager:AllocateDnDID( wtWidget )
    return wtWidget:GetId() * DND_CONTAINER_STEP + DND_GENERIC_WIDGET_USER
end

--------------------------------------------------------------------------------
--- Ищет dndId по любому из связанных виджетов
--- @param wtWidget userdata|table Виджет
--- @return number|nil dndId Идентификатор
--------------------------------------------------------------------------------
function DnDManager:GetWidgetID( wtWidget )
	for dndId, info in pairs( self._widgets ) do
		if info.wtReacting == wtWidget or info.wtMovable == wtWidget then
			return dndId
		end
	end
    
    return nil
end

--------------------------------------------------------------------------------
--- @return boolean active Возвращает true, если есть активное перетаскивание
--------------------------------------------------------------------------------
function DnDManager:IsDragActive()
    return self._activeDrag ~= nil
end

--------------------------------------------------------------------------------
function DnDManager:UnregisterAllEvents()
    if not self._eventHandlers then return end
    
    advEvent.UnRegisterEventHandlers( self, self._eventHandlers )
    self._eventHandlers = nil
end

--------------------------------------------------------------------------------
function DnDManager:_RegisterAllEvents()
    self._eventHandlers = {
        { self.OnPickAttempt, "EVENT_DND_PICK_ATTEMPT" }, -- Попытка начать перетаскивание
        { self.OnDragTo, "EVENT_DND_DRAG_TO" }, -- Перемещение курсора во время перетаскивания
        { self.OnDropAttempt, "EVENT_DND_DROP_ATTEMPT" }, -- Отпускание кнопки мыши
        { self.OnDragCancelled, "EVENT_DND_DRAG_CANCELLED" }, -- Завершение процесса перетаскивания
        { self.OnPosConverterChanged, "EVENT_POS_CONVERTER_CHANGED" }, -- Изменение разрешения экрана / масштаба
    }

    advEvent.RegisterEventHandlers( self, self._eventHandlers )
end

--------------------------------------------------------------------------------
--- @param widget userdata|table Виджет
--- @param argName string Имя аргумента для сообщения об ошибке.
--------------------------------------------------------------------------------
function DnDManager:_ValidateWidget( widget, argName )
    assert( IsWidget( widget ), "FATAL: Widget expected for %s, got %s", argName, apitype( widget ) )
end

--------------------------------------------------------------------------------
--- Проверяет, подходит ли флаг клавиш из события под требуемый модификатор KBF_*.
--- @param requiredKbFlag number|false|nil Требуемый флаг
--- @param eventKbFlags number|nil Флаги из события
--- @return boolean
--------------------------------------------------------------------------------
function DnDManager:_CheckKbFlag( requiredKbFlag, eventKbFlags )
    -- nil/false = без ограничений
    if requiredKbFlag == nil or requiredKbFlag == false then
        return true
    end

    eventKbFlags = eventKbFlags or KBF_NONE

    -- Требуется, чтобы модификаторы были не зажаты
    if requiredKbFlag == KBF_NONE then
        return eventKbFlags == KBF_NONE
    end
    
    return bit.band( eventKbFlags, requiredKbFlag ) ~= 0
end

--------------------------------------------------------------------------------
--- @class DnDPickAttemptParams
--- @field srcWidget Widget - окно, которое пытаются начать перетаскивать.
--- @field srcId number - идентификатор, зарегистрированный для окна, которое пытаются начать перетаскивать.
--- @field posX number - координата курсора по X (реальная).
--- @field posY number - координата курсора по Y (реальная).
--- @field kbFlags number - состояние модификаторов клавиатуры.

--- - EVENT_DND_PICK_ATTEMPT Начало перетаскивания.
--- @param params DnDPickAttemptParams
--------------------------------------------------------------------------------
function DnDManager:OnPickAttempt( params )
    local info = self._widgets[ params.srcId ]

    if not info or not info.enabled or self:IsDragActive() then return end
    -- Проверка модификаторов клавиатуры 
    if not self:_CheckKbFlag( info.kbFlag, params.kbFlags ) then return end
    
    self._activeDrag = {
        info = info,
        startMousePos = {    -- Стартовая позиция мыши
            x = params.posX, -- координата курсора по X (реальная)
            y = params.posY, -- координата курсора по Y (реальная)
        },
        startPlacement = info.wtMovable:GetPlacementPlain(), -- с каких координат всё началось.
    }
    
    if info.lockedToParentArea then
        self._activeDrag.parentSize = self:_GetParentRealSize( info.wtMovable )
    end

    common.SetCursor( info.cursor )
    
    info.wtReacting:DNDConfirmPickAttempt()
end

--------------------------------------------------------------------------------
--- @class DnDDragToParams
--- @field srcWidget Widget - перетаскиваемый виджет.
--- @field srcId number - идентификатор DNDId перетаскиваемого виджета.
--- @field posX number - координата курсора по X (реальная).
--- @field posY number - координата курсора по Y (реальная).
--- @field outside boolean - находится ли курсор за пределами окна приложения.
--- @field kbFlags number - состояние модификаторов клавиатуры.

--- - Перемещение курсора во время drag&drop.
--- - Документация: EVENT_DND_DRAG_TO может прийти после окончания drag&drop.
--- @param params DnDDragToParams
--------------------------------------------------------------------------------
function DnDManager:OnDragTo( params )
    if not self:IsDragActive() then return end
    
    local state = self._activeDrag

    if params.srcId ~= state.info.dndId then return end
    
    local dx = params.posX - state.startMousePos.x
    local dy = params.posY - state.startMousePos.y
    
    if state.info.isResize then
        self:_ProcessResize( state, dx, dy )
    else
        self:_ProcessDrag( state, dx, dy )
    end
    
    if state.info.cursor ~= "default" then
        common.SetCursor( state.info.cursor )
    end
end

--------------------------------------------------------------------------------
--- @param state table Состояние активного перетаскивания.
--- @param dx number Смещение курсора по оси X.
--- @param dy number Смещение курсора по оси Y.
--------------------------------------------------------------------------------
function DnDManager:_ProcessDrag( state, dx, dy )
    local place = state.info.wtMovable:GetPlacementPlain()
    
    if place.alignX ~= WIDGET_ALIGN_LOW_ABS then
        dx = dx * self._screenParams.fullVirtualSizeX / self._screenParams.realSizeX
    end
    
    if place.alignY ~= WIDGET_ALIGN_LOW_ABS then
        dy = dy * self._screenParams.fullVirtualSizeY / self._screenParams.realSizeY
    end
    
    place.posX = math.floor( state.startPlacement.posX + dx )
    place.posY = math.floor( state.startPlacement.posY + dy )
    place.highPosX = math.floor( state.startPlacement.highPosX - dx )
    place.highPosY = math.floor( state.startPlacement.highPosY - dy )
    
    if state.parentSize then
        self:_RestrictPlacement( place, state.parentSize )
    end
    
    state.info.wtMovable:SetPlacementPlain( place )
end

--------------------------------------------------------------------------------
--- @param state table Состояние активного растягивания.
--- @param dx number Смещение курсора по X.
--- @param dy number Смещение курсора по Y.
--------------------------------------------------------------------------------
function DnDManager:_ProcessResize( state, dx, dy )
    local info = state.info
    local plc = table.sclone( state.startPlacement )
    local handlePlc = info.wtReacting:GetPlacementPlain()
    
    local scaleX = ( plc.alignX ~= WIDGET_ALIGN_LOW_ABS ) 
        and ( self._screenParams.fullVirtualSizeX / self._screenParams.realSizeX ) or 1
    local scaleY = ( plc.alignY ~= WIDGET_ALIGN_LOW_ABS ) 
        and ( self._screenParams.fullVirtualSizeY / self._screenParams.realSizeY ) or 1
    
    if info.resizeX then
        self:_ResizeAxis( plc, handlePlc, 'X', dx * scaleX, info.limitsX )
    end
    
    if info.resizeY then
        self:_ResizeAxis( plc, handlePlc, 'Y', dy * scaleY, info.limitsY )
    end
    
    if state.parentSize then
        self:_RestrictPlacement( plc, state.parentSize )
    end
    
    info.wtMovable:SetPlacementPlain( plc )
end

--------------------------------------------------------------------------------
--- Обработка растягивания для конкретной оси.
--- @param plc table WidgetPlacementLua основного виджета
--- @param handlePlc table WidgetPlacementLua маркера
--- @param K string Ось "X" или "Y"
--- @param delta number Смещение курсора по оси, учитывая масштаб
--- @param limits DndResizeHandleLimits Допустимые размеры по оси
--------------------------------------------------------------------------------
function DnDManager:_ResizeAxis( plc, handlePlc, K, delta, limits )
    local sizeK = "size" .. K
    local posK = "pos" .. K
    local highPosK = "highPos" .. K
    local alignK = "align" .. K
    local handleAlign = handlePlc[ alignK ]
    local sizeDelta = ( handleAlign == WIDGET_ALIGN_HIGH ) and delta or -delta
    local newSize = math.clamp( plc[ sizeK ] + sizeDelta, limits.min, limits.max )
    local actualDelta = newSize - plc[ sizeK ]
    
    plc[ sizeK ] = newSize
    
    if plc[ alignK ] == WIDGET_ALIGN_CENTER then
        plc[ posK ] = plc[ posK ] + ( handleAlign == WIDGET_ALIGN_HIGH and actualDelta / 2 or -actualDelta / 2 )
    elseif handleAlign == WIDGET_ALIGN_LOW then
        plc[ posK ] = plc[ posK ] - actualDelta
    elseif handleAlign == WIDGET_ALIGN_HIGH then
        plc[ highPosK ] = plc[ highPosK ] - actualDelta
    end
end

local AXIS_DESCRIPTORS = {
    {
        align = "alignX", pos = "posX", highPos = "highPosX", size = "sizeX", scaleKey = "scaleX",
    },
    {
        align = "alignY", pos = "posY", highPos = "highPosY", size = "sizeY", scaleKey = "scaleY",
    },
}
--------------------------------------------------------------------------------
--- @class DndParentSize
--- @field sizeX number Виртуальная ширина родителя.
--- @field sizeY number Виртуальная высота родителя.

--- Ограничение WidgetPlacementLua в пределах размера родителя
--- @param place table WidgetPlacementLua, который требуется ограничить
--- @param parentSize DndParentSize Виртуальный размер родителя
--- @return table place Ограниченный WidgetPlacementLua
--------------------------------------------------------------------------------
function DnDManager:_RestrictPlacement( place, parentSize )
--[[ ======================BEGIN======================
table(6) {
    ["fullVirtualSizeX"] => number(1920)
    ["fullVirtualSizeY"] => number(1080)
    ["realSizeX"] => number(1600)
    ["realSizeY"] => number(900)
    ["referenceVirtualSizeX"] => number(1920)
    ["referenceVirtualSizeY"] => number(1080)
}
----------------------
table(WidgetPlacementLua:10) {
    ["alignX"] => number(WIDGET_ALIGN_LOW(0))
    ["alignY"] => number(WIDGET_ALIGN_LOW(0))
    ["highPosX"] => number(-1626)
    ["highPosY"] => number(-546)
    ["posX"] => number(1405)
    ["posY"] => number(543)
    ["sizeX"] => number(515)
    ["sizeY"] => number(39)
    ["sizingX"] => number(WIDGET_SIZING_INTERNAL(1))
    ["sizingY"] => number(WIDGET_SIZING_INTERNAL(1))
}
----------------------
table(2) {
    ["sizeX"] => number(1920)
    ["sizeY"] => number(1080)
}
=======================END======================= ]]
    local sp = self._screenParams
    local scales = {
        scaleX = sp.realSizeX / sp.fullVirtualSizeX,
        scaleY = sp.realSizeY / sp.fullVirtualSizeY,
    }
    
    for _, axis in ipairs( AXIS_DESCRIPTORS ) do
        local align = place[ axis.align ]
        local size = place[ axis.size ]
        local parentSizeAxis = parentSize[ axis.size ]
        local scale = scales[ axis.scaleKey ]
        if align == WIDGET_ALIGN_LOW or align == WIDGET_ALIGN_LOW_ABS then
            local maxVal = ( align == WIDGET_ALIGN_LOW_ABS )
                and ( parentSizeAxis - size ) * scale or ( parentSizeAxis - size )
            place[ axis.pos ] = math.clamp( place[ axis.pos ], 0, maxVal )
        elseif align == WIDGET_ALIGN_HIGH then
            place[ axis.highPos ] = math.clamp( place[ axis.highPos ], 0, parentSizeAxis - size )
        elseif align == WIDGET_ALIGN_CENTER then
            local limit = ( parentSizeAxis - size ) / 2
            place[ axis.pos ] = math.clamp( place[ axis.pos ], -limit, limit )
        end
    end
    
    return place
end

--------------------------------------------------------------------------------
--- @class DnDDropAttemptParams
--- @field srcWidget Widget - перетаскиваемый виджет.
--- @field srcId number - идентификатор DNDId перетаскиваемого виджета.
--- @field targetWidget Widget|nil - виджет под курсором.
--- @field targetId number - идентификатор DNDId или DND_INVALID_ID, связанный с виджетом под курсором.
--- @field kbFlags number - состояние модификаторов клавиатуры.

--- - EVENT_DND_DROP_ATTEMPT Попытка завершить drag&drop.
--- @param params DnDDropAttemptParams
--------------------------------------------------------------------------------
function DnDManager:OnDropAttempt( params )
    if not self:IsDragActive() then return end
    if params.srcId ~= self._activeDrag.info.dndId then return end

    self:_StopDragging( true )
end

--------------------------------------------------------------------------------
function DnDManager:OnDragCancelled()
    if not self:IsDragActive() then return end
    self:_StopDragging( false )
end

--------------------------------------------------------------------------------
--- Завершение перетаскивания.
--- @param success boolean Успешно ли завершено перетаскивание.
--------------------------------------------------------------------------------
function DnDManager:_StopDragging( success )
    if not self._activeDrag then return end
    
    local state = self._activeDrag
    
    if success then
        state.info.wtReacting:DNDConfirmDropAttempt()
        
        if state.info.isResize and state.info.resizeCallback then
            InvokeCallback( state.info.resizeCallback, state.info.wtMovable )
        end
        
        local place = state.info.wtMovable:GetPlacementPlain()
        
        if state.parentSize then
            self:_RestrictPlacement( place, state.parentSize )
        end
        
        state.info.wtMovable:SetPlacementPlain( place )
        self:UpdateSavedPlacement( state.info.wtMovable )
    else
        state.info.wtMovable:SetPlacementPlain( state.startPlacement )
    end
    
    self._activeDrag = nil
    common.SetCursor( "default" )
end

--------------------------------------------------------------------------------
--- Возвращает виртуальный размер родителя виджета.
--- @param wtWidget userdata|table Виджет.
--- @return table { sizeX = number, sizeY = number }
--------------------------------------------------------------------------------
function DnDManager:_GetParentRealSize( wtWidget )
    local parent = wtWidget:GetParent()
    if not parent then
        return {
            sizeX = self._screenParams.fullVirtualSizeX,
            sizeY = self._screenParams.fullVirtualSizeY,
        }
    end

    local rect = parent:GetRealRect()
    local scaleX = self._screenParams.fullVirtualSizeX / self._screenParams.realSizeX
    local scaleY = self._screenParams.fullVirtualSizeY / self._screenParams.realSizeY

    return {
        sizeX = ( rect.x2 - rect.x1 ) * scaleX,
        sizeY = ( rect.y2 - rect.y1 ) * scaleY,
    }
end

--------------------------------------------------------------------------------
function DnDManager:OnPosConverterChanged()
    if self:IsDragActive() then
        if self._activeDrag.info.wtReacting:DNDGetState() ~= DND_STATE_NOT_REGISTERED then
            self._activeDrag.info.wtReacting:DNDCancelDrag()
        end
        
        self:_StopDragging( false )
    end
    
    self._screenParams = common.GetPosConverterParams()
    
    for _, info in pairs( self._widgets ) do
        if info.lockedToParentArea and not info.isResize then
            local saved = table.sclone( info.savedPlacement )
            self:_RestrictPlacement( saved, self:_GetParentRealSize( info.wtMovable ) )
            info.wtMovable:SetPlacementPlain( saved )
        end
    end
end

--------------------------------------------------------------------------------
--- Нужен после программного изменения размера виджета извне.
--- @param wtWidget userdata|table Виджет
--------------------------------------------------------------------------------
function DnDManager:UpdateSavedPlacement( wtWidget )
    self:_ValidateWidget( wtWidget, "wtWidget" )
    local dndId = self:GetWidgetID( wtWidget )
    if not dndId then return end
    
    local info = self._widgets[ dndId ]
    if not info then return end
    
    local place = info.wtMovable:GetPlacementPlain()
    
    for _, widgetInfo in pairs( self._widgets ) do
        if widgetInfo.wtMovable == info.wtMovable and not widgetInfo.isResize then
            widgetInfo.savedPlacement = place
        end
    end
    
    if info.saveToConfig then
        self:_SaveConfig( info.configName, place )
    end
end

--------------------------------------------------------------------------------
--- Сохранение WidgetPlacementLua в конфиг.
--- @param name string Имя ключа.
--- @param plc table WidgetPlacementLua.
--------------------------------------------------------------------------------
function DnDManager:_SaveConfig( name, plc )
	if not name then return end
    
    local config = self._options.configProvider.get() or {}
    
    if plc.alignX == WIDGET_ALIGN_HIGH then
        plc.posX = 0
    elseif plc.alignX == WIDGET_ALIGN_LOW or plc.alignX == WIDGET_ALIGN_CENTER then
        plc.highPosX = 0
    end
    
    if plc.alignY == WIDGET_ALIGN_HIGH then
        plc.posY = 0
    elseif plc.alignY == WIDGET_ALIGN_LOW or plc.alignY == WIDGET_ALIGN_CENTER then
        plc.highPosY = 0
    end
    
	config[ name ] = plc
    config.DnD_CONFIG_VERSION = self.__CONFIG_VERSION
    self._options.configProvider.set( config )
end

--------------------------------------------------------------------------------
--- Загрузка WidgetPlacementLua из конфига.
--- @param info table Информация о зарегистрированном виджете.
--------------------------------------------------------------------------------
function DnDManager:_LoadConfig( info )
	local config = self._options.configProvider.get() or {}
    
    if self.__CONFIG_VERSION ~= config.DnD_CONFIG_VERSION then return end
    
    config = config[ info.configName ]

    if not config or type( config ) ~= "table" then return end
    
    local place = info.wtMovable:GetPlacementPlain()
    
    if config.alignX ~= place.alignX or config.alignY ~= place.alignY then
        LogWarning( "DndManager:_LoadConfig alignment discrepancy detected." )
        config.alignX, config.alignY = place.alignX, place.alignY
    end
	
    if info.lockedToParentArea then
        self:_RestrictPlacement( config, self:_GetParentRealSize( info.wtMovable ) )
    end

    info.wtMovable:SetPlacementPlain( config )
end
