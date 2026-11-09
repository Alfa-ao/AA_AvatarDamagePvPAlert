--------------------------------------------------------------------------------
-- Длительность этапов эффекта изменения прозрачности уведомления
local MESSAGE_FADE_IN_TIME_MS = 200
local MESSAGE_FADE_SOLID_TIME_MS = 3000
local MESSAGE_FADE_OUT_TIME_MS = 200
--------------------------------------------------------------------------------
-- Цепочка эффектов изменения прозрачности уведомления
local FADE_EFFECT_SEQUENCE = {
    { 0.0, 1.0, MESSAGE_FADE_IN_TIME_MS },
    { 1.0, 1.0, MESSAGE_FADE_SOLID_TIME_MS },
    { 1.0, 0.0, MESSAGE_FADE_OUT_TIME_MS },
}
--------------------------------------------------------------------------------
-- Общая длительность цепочки эффектов и задержка перед деактивацией
local FADE_EFFECT_TIME = MESSAGE_FADE_IN_TIME_MS + MESSAGE_FADE_SOLID_TIME_MS + MESSAGE_FADE_OUT_TIME_MS
local CLOSE_DELAY = FADE_EFFECT_TIME + 100
--------------------------------------------------------------------------------
-- Таймаут удаления противника из списка в микросекундах
local ENEMY_TIMEOUT_MKS = 3000000
--------------------------------------------------------------------------------
-- Интервал проверки списка противников в миллисекундах
local CHECK_INTERVAL_MS = 500
--------------------------------------------------------------------------------
local localization = common.GetLocalization()
--------------------------------------------------------------------------------
-- Склонение слова противник
local function GetPluralForm( count )
    local n10 = count % 10
    local n100 = count % 100
    
    if n10 == 1 and n100 ~= 11 then
        return GetAddonText( localization, "TEXT_ALERT1" )
    end
    
    return GetAddonText( localization, "TEXT_ALERT2" )
end
--------------------------------------------------------------------------------
Class( "DamageAlert", advWidgetObjectMonitor() )
--------------------------------------------------------------------------------
function DamageAlert:Init()
    self.deferredCallId = false
    self.updateTimerId = false
    self.start = false
    self.enemies = {}
    
    return advWidgetObjectMonitor.Init( self )
end
--------------------------------------------------------------------------------
-- Обновление уведомления
function DamageAlert:Update()
    if self.deferredCallId then
        self:CancelDeferredCall( self.deferredCallId )
        self.deferredCallId = false
    end
    
    if self.object then
        self:SetVal( "value", self.object )
        self:PlayFadeEffectSequence( FADE_EFFECT_SEQUENCE )
        
        self.deferredCallId = self:DeferredCall( self.Close, CLOSE_DELAY )
    else
        self:ClearValues()
    end
end
--------------------------------------------------------------------------------
-- Проверка списка противников и удаление
function DamageAlert:CheckEnemies()
    local currentTime = common.GetMks()
    local hasEnemies = false
    
    if self.updateTimerId then
        self:CancelDeferredCall( self.updateTimerId )
        self.updateTimerId = false
    end
	
    for sourceId, data in pairs( self.enemies ) do
        if currentTime - data.lastHitTime > ENEMY_TIMEOUT_MKS then
            self.enemies[ sourceId ] = nil
        else
            hasEnemies = true
        end
    end
	
    self:UpdateNotification()
	
    if hasEnemies then
        self.updateTimerId = self:DeferredCall( self.CheckEnemies, CHECK_INTERVAL_MS )
    end
end
--------------------------------------------------------------------------------
-- Обновление текста уведомления
function DamageAlert:UpdateNotification()
    local count = table.size( self.enemies )
	
    if count > 0 then
        local limit = math.min( 3, count )
        local i = 1
        local vtFmt = CreateVt {
			format = GetAddonText( localization, "ALERT_TEMPLATE" ),
            plural_form = GetPluralForm( count ),
            count = count,
			class1 = "alert-red-text",
            players = "alert-players-text",
        }

        for _, enemy in pairs( self.enemies ) do
            vtFmt:SetVal( "player" .. i,  enemy.name )
            i = i + 1
            if i > limit then break end
        end
        
        self:Assign( vtFmt )
    else
        self:Assign()
    end
end
--------------------------------------------------------------------------------
-- Закрытие и очистка
function DamageAlert:Close()
    return self:Assign()
end
--------------------------------------------------------------------------------
-- Обработка события получения урона
function DamageAlert:OnUnitDamageReceived( eventData )
    local myId = avatar.GetId()
    if eventData.target ~= myId or not self.start then
        return
    end
    
    local sourceId = eventData.source
    if not sourceId or sourceId == myId then
        return
    end
    
    if object.IsPlayer( sourceId ) then
        self.enemies[ sourceId ] = {
            lastHitTime = common.GetMks(),
            name = object.GetName( sourceId )
        }
        
        self:UpdateNotification()
        
        if self.updateTimerId then
            self:CancelDeferredCall( self.updateTimerId )
        end
        
        self.updateTimerId = self:DeferredCall( self.CheckEnemies, CHECK_INTERVAL_MS )
    end
end
--------------------------------------------------------------------------------
-- Выход из боя и очистка
function DamageAlert:OnUpdateCombat( eventData )
    local myId = avatar.GetId()
    
    if eventData.objectId ~= myId then
        return
    end
    
    if eventData.inCombat then
        self.start = true
        return
    end
    
    self.enemies = {}
    self.start = false
end
--------------------------------------------------------------------------------
function DamageAlert:GetPassiveEventHandlers()
    return {
        { self.OnUnitDamageReceived, "EVENT_UNIT_DAMAGE_RECEIVED" },
        { self.OnUpdateCombat, "EVENT_OBJECT_COMBAT_STATUS_CHANGED" }
    }
end
--------------------------------------------------------------------------------