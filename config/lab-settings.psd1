<#
    CCES R81.20 lab settings - edit this file, not the scripts.
    Every value here can also be overridden with a parameter on the command line.
#>
@{
    # --- hosts ---------------------------------------------------------------
    AEpmName        = 'A-EPM'
    AEpmIp          = '10.1.1.103'
    AEpm02Name      = 'A-EPM-02'
    AEpm02Ip        = '10.1.1.104'

    # --- Gaia credentials (the lab credentials sheet) ------------------------
    GaiaUser        = 'admin'
    GaiaPassword    = 'Chkp!234'

    # SHA-512 hash of the Expert password, used for the non-interactive
    # "set expert-password-hash" path. The hash below is for Chkp!234.
    # Regenerate on any Gaia box with:  openssl passwd -6 '<password>'
    ExpertPassword     = 'Chkp!234'
    ExpertPasswordHash = '$6$PpDz4f8t.euC.3lF$kone5Un4Fsr01bPoES1rKyrXWup8jJ/KFxCL1NEqJTbfjyb.6jqc0XGv3Prxu61QprNgnI0c2ZbaZvlzSjfDq0'

    # --- SmartConsole administrator created by the wizard --------------------
    MgmtAdminUser   = 'cpadmin'
    MgmtAdminPass   = 'Chkp!234'

    # --- Endpoint management object (Lab 2A Task 2A-2, done via mgmt_cli) ----
    AEpmObjectName              = 'A-EPM'
    AEpmNatIp                   = '203.0.113.103'
    EnableEndpointPolicy        = $true
    EnableSmartEventServer      = $false
    EnableSmartEventCorrelation = $true
    EnableLoggingAndStatus      = $true

    # --- SIC one-time password for the secondary management server -----------
    SicKey          = 'Chkp!234'

    # --- files on A-GUI ------------------------------------------------------
    ToolsPath       = 'C:\Users\Admin\Desktop\Check Point Tools'
    LicenseFile     = 'Licenses\A-EPM.lic'
    License02File   = 'Licenses\A-EPM-02.lic'
    ContractFile    = 'Licenses\ServiceContract.xml'
    DeploymentAgent = 'DeploymentAgent_000002337_1.tgz'
    JumboBundle     = 'Check_Point_R81_20_JUMBO_HF_MAIN_Bundle_T26_FULL.tar'

    # --- behaviour -----------------------------------------------------------
    LogPath         = 'C:\CCES-Automation-Logs'
    # Put the admin shell back to Gaia Clish when a script finishes.
    RestoreClishShell = $true
}
