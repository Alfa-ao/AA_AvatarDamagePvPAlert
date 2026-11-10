DamageAlert( mainForm.wtPanel.wtAlert ):Init()

DnDManager:Init()
DnDManager:Register( mainForm.wtPanel, {
    wtReacting = mainForm.wtPanel.wtDragBottomRight,
    saveToConfig = true,
} )