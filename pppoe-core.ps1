# ============================================================
#  PPPoE 拨号核心（由 pppoe-connect.bat 调用，勿单独双击）
#  依赖：Windows 自带 rasdial.exe / rasapi32.dll
#  编码：本文件必须保存为 UTF-8 带 BOM（PS 5.1 才能正确解析中文）
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [string]$EntryName = 'PPPoE-AutoDial',
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
#  输出助手
# ------------------------------------------------------------
function Say([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
}

# ------------------------------------------------------------
#  RAS API 绑定
#  说明：RasSetEntryProperties 的 RASENTRY 结构体很长，这里只填
#  前段字段，dwSize 按完整结构体大小传入，其余字段保持 0。
# ------------------------------------------------------------
$RasSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RASDEVINFO {
    public int dwSize;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szDeviceType;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szDeviceName;
}

[StructLayout(LayoutKind.Sequential)]
public struct RASIPADDR { public byte a, b, c, d; }

// 完整 RASENTRY（对齐 Windows SDK ras.h 的字段顺序）
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RASENTRY {
    public int dwSize;
    public int dwCountryID;
    public int dwCountryCode;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 11)]  public string szAreaCode;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szLocalPhoneNumber;
    public int dwAlternateOffset;
    public RASIPADDR ipaddr;
    public RASIPADDR ipaddrDns;
    public RASIPADDR ipaddrDnsAlt;
    public RASIPADDR ipaddrWins;
    public RASIPADDR ipaddrWinsAlt;
    public int dwFrameSize;
    public int dwNetProtocols;
    public int dwVpnStrategy;
    public int dwMaxSpeed;
    public int dwOptions;
    public int dwOptions2;
    public int dwCustomAuthKey;
    public Guid guidId;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szCustomDialDll;
    public int dwVpnStrategyEx;
    // 后续为预留字段，此处保持结构体到 dwOptions2 之后即可满足 RasSetEntryProperties
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 200)] public byte[] reserved;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RASDIALPARAMS {
    public int dwSize;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szEntryName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szPhoneNumber;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szCallbackNumber;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szUserName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szPassword;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)]  public string szDomain;
    public int dwSubEntry;
    public IntPtr dwCallbackId;
    public int dwIfIndex;
}

public static class Ras {
    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RasSetEntryProperties(string pbk, string entry,
        IntPtr entryPtr, int entrySize, IntPtr devPtr, int devSize);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RasSetCredentials(string pbk, string entry,
        ref RASDIALPARAMS p, bool clear);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RasGetEntryProperties(string pbk, string entry,
        IntPtr entryPtr, ref int entrySize, IntPtr devPtr, ref int devSize);
}

public static class RasUtil {
    // RASENTRY 的真实尺寸固定为 6724 字节（Tail 预留区很大）。
    // 实测：传其他尺寸一律 rc=632；只有 6724 能被接受。
    public const int RASENTRY_SIZE = 6724;
    public const int RASDEVINFO_SIZE = 516;

    public static int EntryExists(string entry) {
        int sz = 0;
        int devSz = 0;
        // 传 IntPtr.Zero 探测所需大小：返回 603 表示条目存在（缓冲太小），623 表示不存在
        int rc = Ras.RasGetEntryProperties(null, entry, IntPtr.Zero, ref sz, IntPtr.Zero, ref devSz);
        if (rc == 603) return 0;
        if (rc == 623) return 623;
        return rc;
    }

    // 用零填充的 6724 字节缓冲 + 手工写关键字段创建 PPPoE 条目。
    // 偏移量均由实测反推（见 ras.h 中 RASENTRY 定义）。
    public static int CreatePppoeEntry(string entry) {
        IntPtr eb = Marshal.AllocHGlobal(RASENTRY_SIZE);
        IntPtr db = Marshal.AllocHGlobal(RASDEVINFO_SIZE);
        try {
            for (int i = 0; i < RASENTRY_SIZE; i++) Marshal.WriteByte(eb, i, 0);
            for (int i = 0; i < RASDEVINFO_SIZE; i++) Marshal.WriteByte(db, i, 0);

            Marshal.WriteInt32(eb, 0, RASENTRY_SIZE);   // dwSize
            Marshal.WriteInt32(eb, 292, 0);              // dwAlternateOffset
            Marshal.WriteInt32(eb, 316, 1500);           // dwFrameSize
            Marshal.WriteInt32(eb, 320, 0x0000000B);     // dwNetProtocols = IP|IPX|NetBEUI

            Marshal.WriteInt32(db, 0, RASDEVINFO_SIZE);  // dwSize
            byte[] dt = Encoding.Unicode.GetBytes("pppoe");
            Marshal.Copy(dt, 0, (IntPtr)(db.ToInt64() + 4), dt.Length);      // szDeviceType
            byte[] dn = Encoding.Unicode.GetBytes("WAN Miniport (PPPOE)");
            Marshal.Copy(dn, 0, (IntPtr)(db.ToInt64() + 260), dn.Length);    // szDeviceName

            return Ras.RasSetEntryProperties(null, entry, eb, RASENTRY_SIZE, db, RASDEVINFO_SIZE);
        } finally {
            Marshal.FreeHGlobal(eb);
            Marshal.FreeHGlobal(db);
        }
    }

    public static int SetCredentials(string entry, string user, string pass) {
        RASDIALPARAMS p = new RASDIALPARAMS();
        p.dwSize = Marshal.SizeOf(typeof(RASDIALPARAMS));
        p.szEntryName = entry;
        p.szPhoneNumber = "";
        p.szCallbackNumber = "";
        p.szUserName = user;
        p.szPassword = pass;
        p.szDomain = "";
        p.dwSubEntry = 0;
        p.dwCallbackId = IntPtr.Zero;
        p.dwIfIndex = 0;
        return Ras.RasSetCredentials(null, entry, ref p, false);
    }
}
'@

function Initialize-Ras {
    if (-not ('RasUtil' -as [type])) {
        Add-Type -TypeDefinition $RasSource -Language CSharp | Out-Null
    }
}

# ------------------------------------------------------------
#  常用 RAS 错误码
# ------------------------------------------------------------
$RasErrors = @{
    600 = '操作未完成'; 601 = '端口无效'; 602 = '端口已被占用'; 603 = '缓冲区太小'
    604 = '设备信息错误'; 605 = '无法设置端口信息'; 606 = '异步宏错误'; 607 = '端口未连接'
    608 = '设备不存在'; 609 = '设备类型不存在'; 610 = '缓冲区无效'; 611 = '路由不可用'
    612 = '路由未分配'; 613 = '压缩无效'; 614 = '缓冲区不足'; 615 = '端口未找到'
    617 = '调制解调器已断开'; 618 = '端口未打开'; 619 = '端口未连接'; 620 = '无端点'
    621 = '无法打开电话簿'; 622 = '无法加载电话簿'; 623 = '找不到电话簿条目'
    624 = '无法写入电话簿'; 625 = '电话簿信息无效'; 626 = '无法加载字符串'
    627 = '无法找到关键词'; 628 = '端口已断开'; 629 = '端口被远端断开'
    630 = '端口无硬件'; 631 = '用户断开'; 632 = '结构大小错误'; 633 = '端口已被占用'
    635 = '未知错误'; 636 = '设备连接到错误端口'; 637 = '字符串无法转换'
    638 = '请求超时'; 639 = '无异步网络可用'; 640 = '发生 NetBIOS 错误'
    641 = '服务器无法分配 NetBIOS 会话'; 642 = '已有 NetBIOS 名称注册'
    643 = '找不到服务器'; 644 = '无法接收网络协议'; 645 = '无法初始化网络'
    646 = '在允许的时间内无法登录'; 647 = '账户已禁用'; 648 = '密码已过期'
    649 = '账户无拨号权限'; 650 = '远程访问服务器无响应'; 651 = '调制解调器报告错误'
    652 = '无法识别的设备响应'; 653 = '找不到设备硬件宏'; 654 = '设备端口无效'
    655 = '找不到消息'; 656 = '找不到设备宏'; 657 = '无法打开设备'
    658 = '设备名称过长'; 659 = '设备名称已在使用'; 660 = '设备响应无效'
    661 = '缺少设备宏'; 662 = '缺少设备宏'; 663 = '媒体类型不匹配'
    665 = '设备未配置'; 666 = '设备无效'; 667 = '无法读取媒体信息'
    668 = '连接已断开'; 669 = '设备信息无效'; 670 = '无法读取连接名称'
    671 = '无法加载媒体 DLL'; 672 = '找不到 IP 地址'; 673 = '用户端口无效'
    674 = '媒体加密失败'; 675 = '准备拨号失败'; 676 = '线路忙'
    677 = '接线员或程序接听'; 678 = '无应答'; 679 = '无法检测载波'
    680 = '无拨号音'; 681 = '设备报告一般性错误'; 682 = '名称已存在于网络上'
    683 = '调制解调器无拨号音'; 684 = '调制解调器无载波'; 685 = '拨号后无应答'
    686 = '接线员未应答'; 687 = '被用户终止'; 688 = '找不到 NetBIOS 名称'
    689 = '已检测到 NetBIOS 会话'; 690 = '异步宏为空'; 691 = '拒绝访问（账号或密码错误）'
    692 = '硬件故障'; 693 = '二进制宏未找到'; 694 = '未找到 RASMAN 条目'
    695 = '状态机错误'; 696 = '状态机未启动'; 697 = '响应环路线程失败'
    698 = '无法读取应答字符串'; 699 = '设备响应缓冲区溢出'
    700 = '设备字符串超出缓冲区'; 701 = '设备已到达最大速度'; 702 = '设备响应无效'
    703 = '连接被终止'; 704 = '错误的数字'; 705 = '无效的授权状态'
    706 = '无法解析 IP 地址'; 707 = '无法解析 IPX 地址'
    708 = '账户已过期'; 709 = '无法更改密码'; 710 = '密码加密错误'
    711 = 'RASMAN 无法初始化'; 712 = '端口冲突'; 713 = '线路断开'
    715 = '通信质量差'; 716 = 'PPP 超时'; 717 = 'PPP 无 IP 地址'
    718 = 'PPP 超时（对方无响应）'; 719 = 'PPP 被远程终止'
    720 = 'PPP 无法建立连接'; 721 = 'PPP 无响应'; 722 = 'PPP 帧错误'
    723 = 'PPP 数据压缩错误'; 724 = 'PPP 无法加载协议'; 725 = 'PPP 无 IPX'
    726 = 'PPP 无法加载 IPX'; 727 = 'PPP 无法加载 IP'; 728 = 'PPP 无法加载 NetBEUI'
    729 = 'PPP 无法加载 SPX'; 730 = 'PPP 无法协商'; 731 = 'PPP 无法协商协议'
    732 = 'PPP 无法协商压缩'; 733 = 'PPP 无法协商加密'; 734 = 'PPP 无法协商 SPX'
    735 = 'PPP 无法协商 IP'; 736 = 'PPP 无法协商 IPX'; 737 = 'PPP 无法协商 NetBEUI'
    738 = 'PPP 无法协商多链路'; 739 = 'PPP 无法协商 PAP'; 740 = 'PPP 无法协商 CHAP'
    741 = 'PPP 无法协商 MSCHAP'; 742 = 'PPP 无法协商数据加密'
    743 = 'PPP 无法协商回调'; 744 = 'PPP 无法协商拨号脚本'
    745 = 'PPP 无法协商 LCP'; 746 = 'PPP 无法协商认证协议'
    747 = 'PPP 无法协商选项'; 748 = 'PPP 无法协商协议'
    749 = 'PPP 无法使用设备'; 750 = 'PPP 无法使用端口'
}

function Explain-RasError([int]$Code) {
    if ($RasErrors.ContainsKey($Code)) { return "$Code - $($RasErrors[$Code])" }
    return "$Code - 未知错误码"
}

# ------------------------------------------------------------
#  主流程
# ------------------------------------------------------------
Say ''
Say '============================================' 'Cyan'
Say '            PPPoE 一键拨号' 'Cyan'
Say '============================================' 'Cyan'
Say ''

# 读取配置（bat 以 UTF-8 写入，此处按 UTF-8 读取）
$user = ''
$pass = ''
if (Test-Path $ConfigPath) {
    foreach ($line in (Get-Content $ConfigPath -Encoding UTF8)) {
        if ($line -match '^\s*user\s*=\s*(.*)$') { $user = $Matches[1].Trim() }
        if ($line -match '^\s*pass\s*=\s*(.*)$') { $pass = $Matches[1].Trim() }
    }
}
if (-not $user -or -not $pass) {
    Say '[错误] 配置文件缺少账号或密码。' 'Red'
    Say "       文件路径：$ConfigPath" 'Red'
    Say '       删除该文件后重新双击脚本即可重新录入。' 'Red'
    exit 1
}

Say "  账号 : $user"
Say "  连接 : $EntryName"
Say '--------------------------------------------'
Say ''

# 确保连接条目存在
try {
    Initialize-Ras
} catch {
    Say "[错误] 初始化 RAS 接口失败：$($_.Exception.Message)" 'Red'
    exit 2
}

# 已连接则先询问
$existing = cmd /c "rasdial `"$EntryName`" 2>&1"
if ($LASTEXITCODE -eq 0) {
    Say '[提示] 当前已处于连接状态。' 'Yellow'
    $ans = Read-Host '       是否断开重拨？(Y=重拨 / 其他键=退出)'
    if ($ans -notmatch '^[Yy]') {
        Say ''
        Say '已保持现有连接，退出。' 'Green'
        exit 0
    }
    cmd /c "rasdial `"$EntryName`" /disconnect" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Say ''
}

if ($Rebuild) {
    cmd /c "rasdial `"$EntryName`" /disconnect" 2>&1 | Out-Null
}

Say '正在准备连接条目...' 'DarkGray'

# 先看目标条目是否存在；不存在则尝试复用系统里现成的 PPPoE 条目
$rcExist = [RasUtil]::EntryExists($EntryName)
if ($rcExist -ne 0) {
    Say "  未找到条目「$EntryName」，尝试创建..." 'DarkGray'

    # 优先复用系统已有的 PPPoE 条目（常见名：宽带连接 / Broadband Connection）
    $fallback = $null
    foreach ($cand in @('宽带连接', 'Broadband Connection', 'PPPoE')) {
        if ([RasUtil]::EntryExists($cand) -eq 0) { $fallback = $cand; break }
    }
    if ($fallback) {
        Say "  发现系统中已有 PPPoE 条目「$fallback」，直接复用它。" 'Green'
        $EntryName = $fallback
    } else {
        $rcEntry = [RasUtil]::CreatePppoeEntry($EntryName)
        if ($rcEntry -ne 0) {
            Say ("[错误] 创建宽带连接失败：{0}" -f (Explain-RasError $rcEntry)) 'Red'
            Say '       常见原因：' 'Red'
            Say '         1) 当前用户电话簿目录无写权限 → 用管理员身份运行一次' 'Red'
            Say '         2) Remote Access Connection Manager (RasMan) 服务未启动' 'Red'
            Say '       替代方案：先在「网络和共享中心 → 设置新连接」里手动建好宽带连接，' 'Red'
            Say '                 再把它的名字填进 pppoe-config.ini 的 entry= 一行。' 'Red'
            exit 3
        }
        Say "  条目「$EntryName」创建成功。" 'Green'
    }
}

$rcCred = [RasUtil]::SetCredentials($EntryName, $user, $pass)
if ($rcCred -ne 0) {
    Say ("[警告] 保存凭证失败：{0}" -f (Explain-RasError $rcCred)) 'Yellow'
    Say '       将改用命令行直接传参拨号。' 'Yellow'
}

Say '正在拨号，请稍候...' 'DarkGray'
Say ''

$out  = cmd /c "rasdial `"$EntryName`" 2>&1"
$code = $LASTEXITCODE
if ($code -ne 0) {
    $out  = cmd /c "rasdial `"$EntryName`" `"$user`" `"$pass`" 2>&1"
    $code = $LASTEXITCODE
}

Say ''
if ($code -eq 0) {
    Say '============================================' 'Green'
    Say '   [成功] PPPoE 已连接，可以上网了！' 'Green'
    Say '============================================' 'Green'
    Say ''
    Say '提示：把本脚本的快捷方式放进「启动」文件夹，可开机自动拨号。' 'DarkGray'
} else {
    Say '============================================' 'Red'
    Say ("   [失败] 拨号未成功：{0}" -f (Explain-RasError $code)) 'Red'
    Say '============================================' 'Red'
    Say ''
    if ($out) { Say ($out | Out-String).Trim() 'DarkGray' }
    Say ''
    Say '排错建议：' 'Yellow'
    Say '  691 / 676  账号或密码错 → 删除配置文件后重新双击录入' 'Yellow'
    Say '  678 / 718  线路无响应   → 检查网线、光猫是否接好' 'Yellow'
    Say '  651        设备报告错误 → 常见于上层已在拨号，见下方说明' 'Yellow'
    Say '  623        条目异常     → 用管理员身份重新运行' 'Yellow'
    Say ''
    Say '★ 若反复报 651 / 678 / 720，请先确认网络拓扑：' 'Cyan'
    Say '  本机若已拿到 192.168.x.x / 10.x.x.x 内网地址，且默认网关是一台路由器，' 'Cyan'
    Say '  说明上层设备已拨号并做了 NAT，本机再执行 PPPoE 是拨不通的。' 'Cyan'
    Say '  要用本机拨号，需先把光猫改成桥接、路由器改成桥接或 AP 模式。' 'Cyan'
}

Say ''
exit $code