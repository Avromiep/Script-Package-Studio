# BatchAV Studio - theme engine
# Every color lives in a named SolidColorBrush inside the merged style dictionary.
# Switching theme mutates brush colors in place, so the whole UI restyles instantly.

$script:ThemePalette = [ordered]@{
    #                     Dark        Light
    BgBrush          = @('#0F1218',  '#F3F5F9')
    PanelBrush       = @('#141824',  '#E9EDF4')
    CardBrush        = @('#1A1F2E',  '#FFFFFF')
    CardHoverBrush   = @('#212840',  '#F0F3FA')
    InputBrush       = @('#12161F',  '#FFFFFF')
    StrokeBrush      = @('#2A3147',  '#D5DBE7')
    StrokeSoftBrush  = @('#232941',  '#E3E8F0')
    TextBrush        = @('#E9ECF4',  '#171B26')
    TextDimBrush     = @('#9AA3B8',  '#5C6579')
    TextFaintBrush   = @('#646E85',  '#8A93A6')
    AccentBrush      = @('#4E8DF5',  '#2E6BE0')
    AccentHoverBrush = @('#6BA1FF',  '#4980E8')
    AccentPressBrush = @('#3D74D6',  '#2358C4')
    AccentSoftBrush  = @('#264E8DF5','#1A2E6BE0')   # translucent accent
    OnAccentBrush    = @('#FFFFFF',  '#FFFFFF')
    SuccessBrush     = @('#43CF8C',  '#149556')
    SuccessSoftBrush = @('#2143CF8C','#18149556')
    WarnBrush        = @('#F2C14E',  '#B07C09')
    WarnSoftBrush    = @('#21F2C14E','#18B07C09')
    ErrorBrush       = @('#F16A73',  '#CC3340')
    ErrorSoftBrush   = @('#21F16A73','#18CC3340')
    InfoBrush        = @('#4EC5F2',  '#0E7FA8')
    SelectionBrush   = @('#2E4E8DF5','#224E8DF5')
    TitleHoverBrush  = @('#22FFFFFF','#14000000')
    LogBgBrush       = @('#0C0F15',  '#FBFCFE')
    Res4KBrush       = @('#C792EA',  '#8B3FC7')
    ResFHDBrush      = @('#61AFEF',  '#1D6FD1')
    ResHDBrush       = @('#43CF8C',  '#149556')
    ResSDBrush       = @('#E5C07B',  '#A67613')
}

function Apply-Theme {
    param([string]$Name)  # 'Dark' or 'Light'
    $idx = if ($Name -eq 'Light') { 1 } else { 0 }
    foreach ($key in $script:ThemePalette.Keys) {
        # brushes loaded from XAML may be frozen - replace the dictionary entry;
        # every consumer uses DynamicResource so the swap propagates instantly
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($script:ThemePalette[$key][$idx])
        $brush = [System.Windows.Media.SolidColorBrush]::new($color)
        $brush.Freeze()
        $script:StyleDict[$key] = $brush
    }
    $script:Settings.theme = $Name
    if ($script:UI.ThemeIcon) {
        # moon glyph in dark mode (click => light), sun in light mode
        $script:UI.ThemeIcon.Text = if ($Name -eq 'Dark') { [char]0xE706 } else { [char]0xE708 }
    }
}
