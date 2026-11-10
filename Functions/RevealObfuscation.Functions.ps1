#Requires -Version 7.0
# =============================================================================
# RevealObfuscation.Functions.ps1
#
# Shared helper functions AND the single-report reveal engine (Invoke-RdaReveal)
# for the reveal feature. Dot-sourced by Reveal.ps1 (and by the child jobs it
# spawns for the multi-subscription path) so they load into that scope.
# Definitions only - no top-level code. Convert-RevealString references
# $Replacements / $tokenPattern / $script:fileHits which Invoke-RdaReveal (its
# caller) establishes before invoking it, so the parent-scope lookup is safe.
# =============================================================================
function ConvertTo-LookupTable
{
    param($MapObject)
    $Table = @{}
    if ($null -ne $MapObject)
    {
        foreach ($Property in $MapObject.PSObject.Properties)
        {
            $Table[$Property.Name] = $Property.Value
        }
    }
    return $Table
}

function Get-RgNameFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)') { return $Matches[1] }
    return $null
}

function Get-SubGuidFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/subscriptions/([^/]+)') { return $Matches[1] }
    return $null
}

# A folder path in one form for comparing: full, with no trailing separator
# (a root such as '/' or 'C:\' keeps its own). 'root/' and 'root' compare equal.
function ConvertTo-RevealComparablePath
{
    param([string]$Path)
    $Full = [System.IO.Path]::GetFullPath($Path)
    $Trimmed = $Full.TrimEnd('\', '/')
    if ($Trimmed.Length -eq 0 -or $Trimmed -match '^[A-Za-z]:$') { return $Full }
    return $Trimmed
}

# The Windows calls that give a file's identity (its volume serial number and
# file id) and its final path, links followed. Loaded once, on Windows only.
function Initialize-RevealWindowsFileId
{
    if ($null -ne ('RevealWindowsFileId' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class RevealWindowsFileId
{
    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    // FILE_READ_ATTRIBUTES; share read, write and delete; OPEN_EXISTING;
    // FILE_FLAG_BACKUP_SEMANTICS so a folder can be opened. Links are followed.
    private static SafeFileHandle Open(string path)
    {
        return CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
    }
    public static string GetIdentity(string path)
    {
        using (SafeFileHandle handle = Open(path))
        {
            if (handle.IsInvalid) { return null; }
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) { return null; }
            return info.VolumeSerialNumber.ToString("X8") + ":" + info.FileIndexHigh.ToString("X8") + info.FileIndexLow.ToString("X8");
        }
    }
    public static string GetFinalPath(string path)
    {
        using (SafeFileHandle handle = Open(path))
        {
            if (handle.IsInvalid) { return null; }
            StringBuilder text = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, text, (uint)text.Capacity, 0);
            if (length == 0 || length >= text.Capacity) { return null; }
            string final = text.ToString();
            if (final.StartsWith(@"\\?\UNC\")) { return @"\\" + final.Substring(8); }
            if (final.StartsWith(@"\\?\")) { return final.Substring(4); }
            return final;
        }
    }
}
'@
}

# The identity of an existing file or folder, links followed, as text: the
# device and inode on Unix, the volume serial number and file id on Windows.
# Two paths with the same identity name the same file or folder, whatever
# their names and whether the folder they are in is case-sensitive (on
# Windows a folder can be made case-sensitive, so a name compare cannot tell).
# $null when the path does not exist or cannot be read.
function Get-RevealPathIdentity
{
    param([Parameter(Mandatory = $true)] [string] $Path)
    if ($IsWindows)
    {
        Initialize-RevealWindowsFileId
        return [RevealWindowsFileId]::GetIdentity($Path)
    }
    # No '--' before the path: macOS stat takes it as a file name. The path is
    # made a full path first, so it starts with '/' and cannot be read as an
    # option. A full path is passed as it is: GetFullPath would drop a '..'
    # by name, where the system reads it from the folder a link leads to.
    $Full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $Text = if (Test-RevealIsMacOS) { & stat -L -f '%d:%i' $Full 2>$null } else { & stat -L -c '%d:%i' $Full 2>$null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$Text)) { return $null }
    return ([string]$Text).Trim()
}

# Whether two paths name the same file or folder. When both exist they are
# compared by identity (Get-RevealPathIdentity); otherwise by their full
# names, as $PathComparison says (the platform default).
function Test-RevealSamePath
{
    param(
        [Parameter(Mandatory = $true)] [string] $Left,
        [Parameter(Mandatory = $true)] [string] $Right,
        [System.StringComparison] $PathComparison = $(if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal })
    )
    if ((Test-Path -LiteralPath $Left) -and (Test-Path -LiteralPath $Right))
    {
        $LeftId = Get-RevealPathIdentity $Left
        $RightId = Get-RevealPathIdentity $Right
        if ($null -ne $LeftId -and $null -ne $RightId) { return $LeftId -ceq $RightId }
    }
    return [string]::Equals((ConvertTo-RevealComparablePath $Left), (ConvertTo-RevealComparablePath $Right), $PathComparison)
}

# Whether $Path (which need not exist) is $Folder itself or anywhere inside
# it, links followed. The nearest existing folder on $Path's way up is found
# by name; from there each folder up to the root is compared with $Folder by
# identity. On Unix the way up is taken through '..', which the system reads
# from the folder a link leads to; on Windows it is taken from the folder's
# final path, links followed.
function Test-RevealPathInside
{
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Folder
    )
    $FolderId = Get-RevealPathIdentity $Folder
    if ($null -eq $FolderId) { return $false }
    $Current = [System.IO.Path]::GetFullPath($Path)
    # A file is in the folder that holds it.
    while (-not (Test-Path -LiteralPath $Current -PathType Container))
    {
        $Current = [System.IO.Path]::GetDirectoryName($Current)
        if ([string]::IsNullOrEmpty($Current)) { return $false }
    }
    if ($IsWindows)
    {
        Initialize-RevealWindowsFileId
        $Final = [RevealWindowsFileId]::GetFinalPath($Current)
        if (-not [string]::IsNullOrEmpty($Final)) { $Current = $Final }
        while (-not [string]::IsNullOrEmpty($Current))
        {
            if ((Get-RevealPathIdentity $Current) -ceq $FolderId) { return $true }
            $Current = [System.IO.Path]::GetDirectoryName($Current)
        }
        return $false
    }
    $Id = Get-RevealPathIdentity $Current
    # A folder tree is far less than 4096 deep; the cap only makes sure the
    # loop ends.
    for ($Depth = 0; $Depth -lt 4096 -and $null -ne $Id; $Depth++)
    {
        if ($Id -ceq $FolderId) { return $true }
        $Current = $Current.TrimEnd('/') + '/..'
        $Up = Get-RevealPathIdentity $Current
        # The root is its own parent.
        if ($Up -ceq $Id) { return $false }
        $Id = $Up
    }
    return $false
}

# True when .NET has File.SetUnixFileMode and GetUnixFileMode (.NET 7 and
# later, so PowerShell 7.3 and later). Its own function so a test can take the
# chmod and stat path on a newer runtime.
function Test-RevealUnixModeApi
{
    $ModeType = 'System.IO.UnixFileMode' -as [type]
    if ($null -eq $ModeType) { return $false }
    return ($null -ne [System.IO.File].GetMethod('SetUnixFileMode', [type[]]@([string], $ModeType)) -and
        $null -ne [System.IO.File].GetMethod('GetUnixFileMode', [type[]]@([string])))
}

# True on macOS, whose stat is the BSD one. Its own function so a test can take
# the macOS path on Linux.
function Test-RevealIsMacOS
{
    return [bool]$IsMacOS
}

# Make a folder readable and writable by its owner only: mode 0700 on Unix,
# and on Windows a protected ACL (no inherited rules) that gives only the
# current user full control. Reveal's staging folder holds real names and ids,
# so it must not stay open to other users of the machine. Throws when the
# folder cannot be set, or does not read back as owner-only.
function Set-RevealOwnerOnlyDirectory
{
    param([Parameter(Mandatory = $true)] [string] $Path)
    Set-RevealOwnerOnlyPath -Path $Path -Directory $true
}

# The same for a file: mode 0600 on Unix, and on Windows a protected ACL that
# gives only the current user full control. Used for each zip Reveal writes,
# which holds real names and ids.
function Set-RevealOwnerOnlyFile
{
    param([Parameter(Mandatory = $true)] [string] $Path)
    Set-RevealOwnerOnlyPath -Path $Path -Directory $false
}

function Set-RevealOwnerOnlyPath
{
    param([Parameter(Mandatory = $true)] [string] $Path, [bool] $Directory)
    if ($IsWindows)
    {
        $User = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($Directory)
        {
            $Security = [System.Security.AccessControl.DirectorySecurity]::new()
            $Inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            $Item = [System.IO.DirectoryInfo]::new($Path)
        }
        else
        {
            $Security = [System.Security.AccessControl.FileSecurity]::new()
            $Inheritance = [System.Security.AccessControl.InheritanceFlags]::None
            $Item = [System.IO.FileInfo]::new($Path)
        }
        $Security.SetAccessRuleProtection($true, $false)
        $Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $Inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $Security.AddAccessRule($Rule)
        [System.IO.FileSystemAclExtensions]::SetAccessControl($Item, $Security)

        $Check = [System.IO.FileSystemAclExtensions]::GetAccessControl($Item)
        $Rules = @($Check.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $Others = @($Rules | Where-Object { $_.IdentityReference.Value -ne $User.Value })
        if (-not $Check.AreAccessRulesProtected -or $Rules.Count -eq 0 -or $Others.Count -gt 0)
        {
            throw "Could not make $Path readable by its owner only."
        }
        return
    }

    # 0700 for a folder, 0600 for a file.
    $Want = if ($Directory) { 0x1C0 } else { 0x180 }
    if (Test-RevealUnixModeApi)
    {
        $Flags = if ($Directory) { 'UserRead, UserWrite, UserExecute' } else { 'UserRead, UserWrite' }
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]$Flags)
        $Mode = [int][System.IO.File]::GetUnixFileMode($Path)
    }
    else
    {
        # PowerShell 7.0 and 7.1 run on .NET before 7, which has no Unix mode
        # calls. Use the plain chmod form every Unix has, and read the mode
        # back with the stat of this system: BSD stat on macOS, GNU stat on
        # Linux. No '--' before the path: macOS chmod and stat take it as a
        # file name and fail. The path is made a full path first, so it starts
        # with '/' and cannot be read as an option.
        $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $Octal = [Convert]::ToString($Want, 8)
        & chmod $Octal $Path
        if ($LASTEXITCODE -ne 0) { throw "Could not make $Path readable by its owner only (chmod ended with $LASTEXITCODE)." }
        $Text = if (Test-RevealIsMacOS) { & stat -f '%Lp' $Path } else { & stat -c '%a' $Path }
        if ($LASTEXITCODE -ne 0) { throw "Could not read the mode of $Path (stat ended with $LASTEXITCODE)." }
        $Mode = [Convert]::ToInt32(([string]$Text).Trim(), 8)
    }
    if (($Mode -band 0x1FF) -ne $Want)
    {
        throw ("Could not make {0} readable by its owner only: its mode is {1}." -f $Path, [Convert]::ToString($Mode -band 0x1FF, 8))
    }
}

# True when .NET can give a new file its Unix mode as it creates it
# (FileStreamOptions.UnixCreateMode, .NET 7 and later, so PowerShell 7.3 and
# later). Its own function so a test can take the other path.
function Test-RevealUnixCreateModeApi
{
    $OptionsType = 'System.IO.FileStreamOptions' -as [type]
    return ($null -ne $OptionsType -and $null -ne $OptionsType.GetProperty('UnixCreateMode'))
}

# True when .NET can create a file with a given ACL
# (FileSystemAclExtensions.Create with a FileSecurity). Its own function so a
# test can take the other path.
function Test-RevealAclCreateApi
{
    $Extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($null -eq $Extensions) { return $false }
    return ($null -ne $Extensions.GetMethod('Create', [type[]]@([System.IO.FileInfo], [System.IO.FileMode], [System.Security.AccessControl.FileSystemRights], [System.IO.FileShare], [int], [System.IO.FileOptions], [System.Security.AccessControl.FileSecurity])))
}

# Make a new, empty file at $Path that only its owner can read (see
# Set-RevealOwnerOnlyFile), before anything is written into it. The file is
# owner-only from the moment it exists, so no other user can open it in
# between and keep it open while real values are written:
#  - on Unix with .NET 7 or later it is created with mode 0600;
#  - on Windows with the ACL create call it is created with the protected
#    owner-only ACL;
#  - otherwise it is created inside a new owner-only folder beside $Path (the
#    same volume), made owner-only there, and then moved to $Path, which keeps
#    its mode on Unix and its ACL on Windows.
# It is then checked as owner-only. A file already at $Path is removed first,
# so the new one never keeps its permissions. The path must be a full path.
function New-RevealOwnerOnlyFile
{
    param([Parameter(Mandatory = $true)] [string] $Path)
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    $Created = $false
    try
    {
        if ($IsWindows -and (Test-RevealAclCreateApi))
        {
            $Security = [System.Security.AccessControl.FileSecurity]::new()
            $Security.SetAccessRuleProtection($true, $false)
            $Security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow))
            $Stream = [System.IO.FileSystemAclExtensions]::Create([System.IO.FileInfo]::new($Path), [System.IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None, $Security)
            $Created = $true
            $Stream.Dispose()
        }
        elseif (-not $IsWindows -and (Test-RevealUnixCreateModeApi))
        {
            $Options = [System.IO.FileStreamOptions]::new()
            $Options.Mode = [System.IO.FileMode]::CreateNew
            $Options.Access = [System.IO.FileAccess]::Write
            $Options.Share = [System.IO.FileShare]::None
            $Options.UnixCreateMode = [System.IO.UnixFileMode]'UserRead, UserWrite'
            $Stream = [System.IO.FileStream]::new($Path, $Options)
            $Created = $true
            $Stream.Dispose()
        }
        else
        {
            $Parent = [System.IO.Path]::GetDirectoryName($Path)
            $Private = Join-Path $Parent ('.reveal-new-' + [guid]::NewGuid().ToString('N'))
            $null = [System.IO.Directory]::CreateDirectory($Private)
            try
            {
                Set-RevealOwnerOnlyDirectory -Path $Private
                $Inner = Join-Path $Private 'new'
                $Stream = [System.IO.FileStream]::new($Inner, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $Stream.Dispose()
                Set-RevealOwnerOnlyFile -Path $Inner
                # No overwrite: a file someone put at $Path meanwhile is not
                # taken over.
                [System.IO.File]::Move($Inner, $Path)
                $Created = $true
            }
            finally { Remove-Item -LiteralPath $Private -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Set-RevealOwnerOnlyFile -Path $Path
    }
    catch
    {
        if ($Created) { [System.IO.File]::Delete($Path) }
        throw ("Reveal will not write real names and ids into {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

# Write a zip of every file under $SourceDirectory to $Path, owner-only from
# the start (New-RevealOwnerOnlyFile). The entries are the same as
# ZipFile.CreateFromDirectory writes with no base folder: each file by its
# path under $SourceDirectory with '/' between parts, and an entry ending in
# '/' for each empty folder.
function Write-RevealZipFromDirectory
{
    param([Parameter(Mandatory = $true)] [string] $SourceDirectory, [Parameter(Mandatory = $true)] [string] $Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Base = [System.IO.DirectoryInfo]::new($SourceDirectory)
    $BaseLength = $Base.FullName.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar).Length + 1
    New-RevealOwnerOnlyFile -Path $Path
    $Stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try
    {
        $Archive = [System.IO.Compression.ZipArchive]::new($Stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try
        {
            foreach ($Item in $Base.EnumerateFileSystemInfos('*', [System.IO.SearchOption]::AllDirectories))
            {
                $Name = $Item.FullName.Substring($BaseLength).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
                if ($Item -is [System.IO.FileInfo])
                {
                    $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $Item.FullName, $Name, [System.IO.Compression.CompressionLevel]::Optimal)
                }
                elseif (-not $Item.EnumerateFileSystemInfos().GetEnumerator().MoveNext())
                {
                    $null = $Archive.CreateEntry($Name + '/')
                }
            }
        }
        finally { $Archive.Dispose() }
    }
    finally { $Stream.Dispose() }
}

# Write a zip of the given files, each at the top by its file name, to $Path,
# owner-only from the start. Used for the all-subscriptions outer zip.
function Write-RevealZipFromFiles
{
    param([Parameter(Mandatory = $true)] [string[]] $Files, [Parameter(Mandatory = $true)] [string] $Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-RevealOwnerOnlyFile -Path $Path
    $Stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try
    {
        $Archive = [System.IO.Compression.ZipArchive]::new($Stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try
        {
            foreach ($File in $Files)
            {
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $File, [System.IO.Path]::GetFileName($File), [System.IO.Compression.CompressionLevel]::Optimal)
            }
        }
        finally { $Archive.Dispose() }
    }
    finally { $Stream.Dispose() }
}

# The zip limits the ingestion server holds every uploaded zip to: at most
# 2000 files, at most 100 to 1 compression (all files' sizes over the zip's
# own size), no file over 16 GB, at most 32 GB in all, and no file path that
# is rooted or has a '..' part. Reveal holds each zip it opens and each zip it
# writes to the same limits, so it neither expands a report that would fill
# the disk nor says a bundle is ready that the server must refuse. The limits
# are parameters so a test can use small ones.
function Get-RevealZipLimitProblem
{
    param(
        [Parameter(Mandatory = $true)] [System.IO.Compression.ZipArchive] $Archive,
        [long]   $CompressedLength = 0,
        [int]    $MaxEntries = 2000,
        [double] $MaxRatio = 100,
        [long]   $MaxEntryBytes = 16GB,
        [long]   $MaxTotalBytes = 32GB
    )
    $Entries = $Archive.Entries
    if ($Entries.Count -gt $MaxEntries) { return ('it holds {0} files, more than the {1} allowed' -f $Entries.Count, $MaxEntries) }
    $Total = [long]0
    foreach ($Entry in $Entries)
    {
        $Name = $Entry.FullName
        if (-not [string]::IsNullOrWhiteSpace($Name))
        {
            # IsPathRooted follows the host, so on Linux and macOS it does not
            # see a Windows drive ('C:/x', 'C:\x' or the drive-relative 'C:x').
            # Those, and '/' or '\' names (UNC '\\server' among them), are
            # refused on every host.
            if ([System.IO.Path]::IsPathRooted($Name) -or $Name.StartsWith('/') -or $Name.StartsWith('\') -or $Name -match '\A[A-Za-z]:')
            {
                return ("it holds the file '{0}', whose path is rooted" -f $Name)
            }
            $Normal = $Name.Replace('\', '/')
            if ($Normal.Contains('../') -or $Normal.Contains('/..') -or $Normal -eq '..')
            {
                return ("it holds the file '{0}', whose path has a '..' part" -f $Name)
            }
        }
        if ($Entry.Length -gt $MaxEntryBytes) { return ("it holds the file '{0}' of {1} bytes, more than the {2} bytes allowed for one file" -f $Name, $Entry.Length, $MaxEntryBytes) }
        $Total += $Entry.Length
    }
    if ($Total -gt $MaxTotalBytes) { return ('its files hold {0} bytes in all, more than the {1} bytes allowed' -f $Total, $MaxTotalBytes) }
    if ($CompressedLength -gt 0 -and $Total -gt 0)
    {
        $Ratio = [double]$Total / $CompressedLength
        if ($Ratio -gt $MaxRatio) { return ('its files are {0:0.#} times the size of the zip, more than the {1} to 1 allowed' -f $Ratio, $MaxRatio) }
    }
    return $null
}

# Throw a plain message when the zip at $Path breaks a limit of
# Get-RevealZipLimitProblem. $What names the zip in the message.
function Assert-RevealZipWithinLimits
{
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [string] $What = 'zip',
        [hashtable] $Limits = @{}
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try
    {
        $Archive = [System.IO.Compression.ZipArchive]::new($Stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
        try { Assert-RevealOpenZipWithinLimits -Archive $Archive -CompressedLength $Stream.Length -Path $Path -What $What -Limits $Limits }
        finally { $Archive.Dispose() }
    }
    finally { $Stream.Dispose() }
}

# The same check on a zip that is already open, so the archive checked is the
# one then read.
function Assert-RevealOpenZipWithinLimits
{
    param(
        [Parameter(Mandatory = $true)] [System.IO.Compression.ZipArchive] $Archive,
        [long] $CompressedLength,
        [string] $Path,
        [string] $What = 'zip',
        [hashtable] $Limits = @{}
    )
    $Problem = Get-RevealZipLimitProblem -Archive $Archive -CompressedLength $CompressedLength @Limits
    if ($null -ne $Problem)
    {
        throw ("The {0} {1} is over the zip limits the ingestion server holds every zip to: {2}. (A zip may hold at most 2000 files, at most 100 to 1 compression, no file over 16 GB, at most 32 GB in all, and no rooted or '..' path.)" -f $What, $Path, $Problem)
    }
}

function Get-JsonEscaped
{
    # Return the input string escaped for placement INSIDE a JSON string literal
    # (ConvertTo-Json wraps + escapes; strip the surrounding quotes).
    param([string]$Text)
    $Json = $Text | ConvertTo-Json -Compress
    return $Json.Substring(1, $Json.Length - 2)
}

# Reveal selected tokens inside a single string. The replacement value is
# escaped to match the destination format so a revealed value containing
# special characters (e.g. a subscription display name with '&', or a
# free-text tag value) stays valid in that file:
#   Json -> escaped for a JSON string literal
#   Html -> HTML-entity encoded (the report encodes every rendered value)
#   None -> raw (CSV field values are re-quoted by Export-Csv instead)
# Tokens not in $Replacements are returned unchanged, so unselected
# dimensions stay masked. Increments $script:fileHits per substituted token.
function Convert-RevealString
{
    param([string]$Text, [string]$EscapeMode = 'None')
    # Fast path: every obfuscation token starts with the literal 'prod_' or
    # 'nonprod_' prefix (plain or type-hinted, e.g. prod_<guid> / prod_aks_<guid>),
    # so text containing neither substring cannot contain a token - return it
    # unchanged and skip the comparatively expensive regex scan. This is the hot
    # path for the large Consumption CSV, whose cells are overwhelmingly dates,
    # numbers and meter names with no token: it turns a per-cell regex sweep over
    # 100k+ rows (minutes) into a substring test. Correctness is unchanged - the
    # regex callback only ever substitutes tokens found in $Replacements, and any
    # skipped text provably has no token to substitute.
    if (-not ($Text.Contains('prod_') -or $Text.Contains('nonprod_')))
    {
        return $Text
    }
    return [regex]::Replace($Text, $TokenPattern, {
            param($m)
            $Tok = $m.Value
            if ($Replacements.ContainsKey($Tok))
            {
                $script:FileHits++
                $Val = $Replacements[$Tok]
                switch ($EscapeMode)
                {
                    'Json' { return (Get-JsonEscaped $Val) }
                    'Html' { return [System.Net.WebUtility]::HtmlEncode($Val) }
                    default { return $Val }
                }
            }
            return $Tok
        })
}

# The value -Obfuscate writes for an id or name it could not mask: the word
# 'obfuscated', or 'obfuscated_' + a GUID. It has no dictionary entry.
function Get-RevealSentinelPattern
{
    return 'obfuscated(?:_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?'
}

# Whether one scan window of a JSON member ends with a whole sentinel string
# followed only by white space, so the ',' ']' or '}' that would make it a value
# is not in the window yet. A match at the start of a window that is not the
# member's start is skipped, as in Test-RevealSentinelInText.
function Test-RevealJsonSentinelOpenAtEnd
{
    param([string] $Text, [bool] $AtStart)
    if (-not $Text.Contains('obfuscated')) { return $false }
    $Pattern = '(?<!\\)"' + (Get-RevealSentinelPattern) + '"\s*\z'
    foreach ($M in [regex]::Matches($Text, $Pattern))
    {
        if ($M.Index -eq 0 -and -not $AtStart) { continue }
        return $true
    }
    return $false
}

# Whether one scan window of a .json or .csv member holds the sentinel as a
# WHOLE value: a JSON string value exactly equal to it, or a CSV cell exactly
# equal to it (quoted or not). The bare word in other text (a longer string,
# a JSON key, part of a quoted CSV cell) does not count.
#   $AtStart      - the window starts at the start of the member
#   $AtEnd        - the window ends at the end of the member
#   $QuotesBefore - CSV only: the number of '"' in the member before the window
# A match that touches the start or end of a window that is not the member's
# start or end is skipped: the scan carries the end of each window into the
# next one, so such a match is checked there with the characters around it.
function Test-RevealSentinelInText
{
    param(
        [string] $Text,
        [ValidateSet('Json', 'Csv')]
        [string] $Kind,
        [bool]   $AtStart,
        [bool]   $AtEnd,
        [long]   $QuotesBefore = 0
    )
    if (-not $Text.Contains('obfuscated')) { return $false }

    $Sentinel = Get-RevealSentinelPattern

    if ($Kind -eq 'Json')
    {
        # A string value: an opening quote that is not escaped, the sentinel, a
        # closing quote, then (after any white space) the ',' ']' or '}' that
        # ends a value. A key is followed by ':' instead.
        $Pattern = '(?<!\\)"' + $Sentinel + '"(?=\s*[,\]}])'
        foreach ($M in [regex]::Matches($Text, $Pattern))
        {
            if ($M.Index -eq 0 -and -not $AtStart) { continue }
            return $true
        }
        return $false
    }

    # CSV: the cell must start at the start of a line or after ',', end at ','
    # or the end of a line, and lie outside a quoted field (an even number of
    # '"' before it in the member; an escaped '""' keeps the count even).
    $Pattern = '(?<q>"?)' + $Sentinel + '\k<q>'
    $Counted = 0
    $Quotes = $QuotesBefore
    foreach ($M in [regex]::Matches($Text, $Pattern))
    {
        $Start = $M.Index
        $End = $M.Index + $M.Length
        if ($Start -eq 0)
        {
            if (-not $AtStart) { continue }
        }
        elseif (@(',', "`n", "`r") -notcontains [string]$Text[$Start - 1]) { continue }
        if ($End -eq $Text.Length)
        {
            if (-not $AtEnd) { continue }
        }
        elseif (@(',', "`n", "`r") -notcontains [string]$Text[$End]) { continue }

        $Between = $Text.Substring($Counted, $Start - $Counted)
        $Quotes += $Between.Length - $Between.Replace('"', '').Length
        $Counted = $Start
        if ($Quotes % 2 -eq 0) { return $true }
    }
    return $false
}

# Whether a report zip holds any masked value: a prod_/nonprod_ token in any
# member, or the 'obfuscated' sentinel as a whole value in a .json or .csv
# member (see Test-RevealSentinelInText). Used when the dictionary gives
# nothing to reveal, to tell a report with no masked values (a subscription
# with no resources) from one revealed with the wrong dictionary or -Fields.
function Test-RevealZipHasMaskedValue
{
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TokenPattern
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try
    {
        # A zip over the limits is not read at all.
        Assert-RevealOpenZipWithinLimits -Archive $Archive -CompressedLength ([System.IO.FileInfo]::new($Path).Length) -Path $Path -What 'report zip'
        # Each entry is read in fixed chunks of 64 KB characters, not line by
        # line: Inventory_*.json and Metrics_*.json are written on one line, so a
        # line can be the whole entry. Each chunk is scanned with the last
        # ($MaxTokenLength - 1) characters of the previous chunk in front of it,
        # so a value split across two chunks is still found. $MaxTokenLength
        # (128) covers 'nonprod_' + a type hint of up to 83 characters + '_' + a
        # GUID; the longest hint the tool writes is 'databricks'. The quoted
        # sentinel with a GUID is 49 characters. The scan stops at the first
        # masked value, so at most one chunk plus the carry-over is held in memory.
        $ChunkLength = 65536
        $MaxTokenLength = 128
        $CarryLength = $MaxTokenLength - 1
        $Buffer = [char[]]::new($CarryLength + $ChunkLength)
        foreach ($Entry in $Archive.Entries)
        {
            $Kind = switch ([System.IO.Path]::GetExtension($Entry.FullName).ToLowerInvariant())
            {
                '.json' { 'Json' }
                '.csv' { 'Csv' }
                default { $null }
            }
            $Reader = [System.IO.StreamReader]::new($Entry.Open())
            try
            {
                $Kept = 0
                $AtStart = $true
                $QuotesBefore = [long]0
                # JSON only: an earlier window ended with a whole sentinel
                # string and white space, so whether it is a value depends on
                # the first other character after it. The carry alone cannot
                # hold that: white space longer than the carry pushes the
                # string out of the next window.
                $JsonOpen = $false
                while ($true)
                {
                    $Read = $Reader.ReadBlock($Buffer, $Kept, $ChunkLength)
                    $Filled = $Kept + $Read
                    if ($Filled -eq 0) { break }
                    # ReadBlock returns less than asked only at the end of the
                    # stream. A full read is followed by one more, so a stream
                    # that ends on a chunk boundary rescans its carry-over with
                    # $AtEnd set.
                    $AtEnd = $Read -lt $ChunkLength
                    $Text = [string]::new($Buffer, 0, $Filled)
                    if ([regex]::IsMatch($Text, $TokenPattern)) { return $true }
                    $NewIsBlank = $false
                    if ($JsonOpen)
                    {
                        # The characters this window added after the carry.
                        $Next = [regex]::Match($Text.Substring($Kept), '\S')
                        if ($Next.Success)
                        {
                            if (@(',', ']', '}') -contains $Next.Value) { return $true }
                        }
                        else { $NewIsBlank = $true }
                    }
                    if ($null -ne $Kind -and (Test-RevealSentinelInText -Text $Text -Kind $Kind -AtStart $AtStart -AtEnd $AtEnd -QuotesBefore $QuotesBefore))
                    {
                        return $true
                    }
                    if ($AtEnd) { break }
                    if ($Kind -eq 'Json')
                    {
                        $JsonOpen = ($JsonOpen -and $NewIsBlank) -or (Test-RevealJsonSentinelOpenAtEnd -Text $Text -AtStart $AtStart)
                    }
                    $Kept = [Math]::Min($CarryLength, $Filled)
                    if ($Kind -eq 'Csv')
                    {
                        $Dropped = $Text.Substring(0, $Filled - $Kept)
                        $QuotesBefore += $Dropped.Length - $Dropped.Replace('"', '').Length
                    }
                    [Array]::Copy($Buffer, $Filled - $Kept, $Buffer, 0, $Kept)
                    $AtStart = $false
                }
            }
            finally { $Reader.Dispose() }
        }
    }
    finally
    {
        $Archive.Dispose()
    }
    return $false
}


# Every token a dictionary knows: the keys of all its maps, whichever fields
# are selected. A report whose masked values include one of these belongs to
# that dictionary.
function Get-RevealDictionaryTokenSet
{
    param($Dictionary)
    $Tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($MapName in @('ResourceGroupMap', 'SubscriptionMap', 'SubscriptionNameMap', 'TagMap', 'ResourceIdMap', 'ResourceNameMap', 'FreeTextMap'))
    {
        $Map = $Dictionary.$MapName
        if ($null -eq $Map) { continue }
        foreach ($Property in $Map.PSObject.Properties) { $null = $Tokens.Add([string]$Property.Name) }
    }
    return , $Tokens
}

# Whether a report zip holds at least one prod_/nonprod_ token that is in
# $KnownTokens (see Get-RevealDictionaryTokenSet). Read in the same fixed-size
# chunks as Test-RevealZipHasMaskedValue, with the end of each chunk carried
# into the next, and stops at the first known token.
function Test-RevealZipHasKnownToken
{
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $TokenPattern,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $KnownTokens
    )
    if ($KnownTokens.Count -eq 0) { return $false }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try
    {
        # A zip over the limits is not read at all.
        Assert-RevealOpenZipWithinLimits -Archive $Archive -CompressedLength ([System.IO.FileInfo]::new($Path).Length) -Path $Path -What 'report zip'
        $ChunkLength = 65536
        $CarryLength = 127
        $Buffer = [char[]]::new($CarryLength + $ChunkLength)
        foreach ($Entry in $Archive.Entries)
        {
            $Reader = [System.IO.StreamReader]::new($Entry.Open())
            try
            {
                $Kept = 0
                while ($true)
                {
                    $Read = $Reader.ReadBlock($Buffer, $Kept, $ChunkLength)
                    $Filled = $Kept + $Read
                    if ($Filled -eq 0) { break }
                    $Text = [string]::new($Buffer, 0, $Filled)
                    foreach ($M in [regex]::Matches($Text, $TokenPattern))
                    {
                        if ($KnownTokens.Contains($M.Value)) { return $true }
                    }
                    if ($Read -lt $ChunkLength) { break }
                    $Kept = [Math]::Min($CarryLength, $Filled)
                    [Array]::Copy($Buffer, $Filled - $Kept, $Buffer, 0, $Kept)
                }
            }
            finally { $Reader.Dispose() }
        }
    }
    finally
    {
        $Archive.Dispose()
    }
    return $false
}

# Whether the dictionary holds any value for the selected fields. When it does
# not, the selection has nothing to reveal in this report.
function Test-RevealDictionaryHasSelectedValue
{
    param($Dictionary, [string[]] $Fields)
    $MapOfField = @{
        ResourceGroup = 'ResourceGroupMap'
        Subscription  = 'SubscriptionMap'
        Tag           = 'TagMap'
        ResourceName  = 'ResourceNameMap'
        ResourceId    = 'ResourceIdMap'
        FreeText      = 'FreeTextMap'
    }
    foreach ($Field in $Fields)
    {
        $Map = $Dictionary.($MapOfField[$Field])
        if ($null -eq $Map) { continue }
        foreach ($Property in $Map.PSObject.Properties)
        {
            if (-not [string]::IsNullOrEmpty([string]$Property.Value)) { return $true }
        }
    }
    return $false
}

# One report of an all-subscriptions reveal (Reveal.ps1 runs this in a child
# job for each folder). The -Fields choice applies to every subscription, and
# one of them may have no value for a selected field (for example -Fields Tag
# and a subscription with no tags). When the report's own dictionary has no
# value for the selected fields, but the report's masked values are in that
# dictionary (so it is the right dictionary), there is nothing to reveal and
# the report is written unchanged. Every other case goes to Invoke-RdaReveal,
# which still fails a report revealed with a dictionary it has no entry in.
function Invoke-RdaRevealFolder
{
    param(
        [Parameter(Mandatory = $true)] [string]   $InputZip,
        [Parameter(Mandatory = $true)] [string]   $DictionaryPath,
        [Parameter(Mandatory = $true)] [string[]] $Fields,
        [Parameter(Mandatory = $true)] [string]   $OutputZip,
        [string] $TempDirectory
    )
    $ErrorActionPreference = 'Stop'
    $Dict = Get-Content -LiteralPath $DictionaryPath -Raw | ConvertFrom-Json
    if (-not (Test-RevealDictionaryHasSelectedValue -Dictionary $Dict -Fields $Fields))
    {
        $TokenPattern = Get-RevealTokenPattern
        if ((Test-RevealZipHasMaskedValue -Path $InputZip -TokenPattern $TokenPattern) -and
            (Test-RevealZipHasKnownToken -Path $InputZip -TokenPattern $TokenPattern -KnownTokens (Get-RevealDictionaryTokenSet $Dict)))
        {
            Copy-RevealZipUnchanged -InputZip $InputZip -OutputZip $OutputZip
            Write-Host ("Nothing to reveal: this report's dictionary has no value for the selected field(s) [{0}]. Wrote an unchanged copy." -f ($Fields -join ', ')) -ForegroundColor Yellow
            return
        }
    }
    Invoke-RdaReveal -InputZip $InputZip -DictionaryPath $DictionaryPath -Fields $Fields -OutputZip $OutputZip -TempDirectory $TempDirectory
}

# The prod_/nonprod_ token shapes: plain prod_/nonprod_<guid> and type-hinted
# name tokens (prod_aks_<guid>, etc.).
function Get-RevealTokenPattern
{
    return '(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
}

# Write an unchanged copy of a report: copy to a sibling .partial.zip, then
# move it into place, the same atomic swap a revealed zip gets.
function Copy-RevealZipUnchanged
{
    param([string] $InputZip, [string] $OutputZip)
    $OutputZipPartial = ($OutputZip -replace '\.zip$', '') + '.partial.zip'
    # The copy holds the report as it is, so it is owner-only from the start,
    # as a revealed zip is.
    New-RevealOwnerOnlyFile -Path $OutputZipPartial
    $Source = [System.IO.File]::OpenRead($InputZip)
    try
    {
        $Target = [System.IO.FileStream]::new($OutputZipPartial, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $Source.CopyTo($Target) } finally { $Target.Dispose() }
    }
    finally { $Source.Dispose() }
    try { Assert-RevealZipWithinLimits -Path $OutputZipPartial -What 'revealed zip' }
    catch { Remove-Item -LiteralPath $OutputZipPartial -Force -ErrorAction SilentlyContinue; throw }
    [System.IO.File]::Move($OutputZipPartial, $OutputZip, $true)
}

# Copy the revealed sibling $From over the member $To and remove $From. The
# member is truncated and written in place, so it keeps its own permissions,
# as the earlier in-place rewrite did.
function Copy-RevealSiblingOver
{
    param([Parameter(Mandatory = $true)] [string] $From, [Parameter(Mandatory = $true)] [string] $To)
    $Source = [System.IO.FileStream]::new($From, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try
    {
        $Target = [System.IO.FileStream]::new($To, [System.IO.FileMode]::Truncate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $Source.CopyTo($Target) } finally { $Target.Dispose() }
    }
    finally { $Source.Dispose() }
    [System.IO.File]::Delete($From)
}

# Reveal one CSV member, row by row. Field-aware: the rows go back through the
# CSV writer, so a revealed value holding a comma or a quote is quoted and
# cannot break the columns, as a raw text replace could. Import-Csv streams
# each row through ForEach-Object to Export-Csv, which writes the same bytes
# as exporting all rows at once, into an owner-only sibling. The member is
# replaced only when a token was revealed. Counts in $script:FileHits, read by
# the caller; $Replacements and $TokenPattern come from the caller's scope
# (see Convert-RevealString).
function Convert-RevealCsvFile
{
    param([Parameter(Mandatory = $true)] [string] $Path)
    # A new name, so no member of the report is ever taken for it.
    $Sibling = $Path + '.' + [guid]::NewGuid().ToString('N') + '.reveal-partial'
    New-RevealOwnerOnlyFile -Path $Sibling
    try
    {
        Import-Csv -LiteralPath $Path | ForEach-Object {
            foreach ($prop in $_.PSObject.Properties)
            {
                if ($null -ne $prop.Value -and $prop.Value -is [string] -and $prop.Value.Length -gt 0)
                {
                    $prop.Value = Convert-RevealString -Text $prop.Value -EscapeMode 'None'
                }
            }
            $_
        } | Export-Csv -LiteralPath $Sibling -NoTypeInformation -Encoding utf8
        if ($script:FileHits -gt 0) { Copy-RevealSiblingOver -From $Sibling -To $Path }
    }
    finally
    {
        if ([System.IO.File]::Exists($Sibling)) { [System.IO.File]::Delete($Sibling) }
    }
}

# Reveal one text member (.json, .html or other) in chunks of 64 KB
# characters, so a member written on one line is never held whole. The text
# is decoded as Get-Content does (UTF-8, or the encoding its byte order mark
# names) and written as UTF-8 with no byte order mark and nothing added, as
# Set-Content -Encoding utf8 -NoNewline did, into an owner-only sibling. Each
# chunk is revealed up to a cut point 127 characters before its end, moved
# back to the start of a token that crosses it; the text after the cut is
# carried in front of the next chunk. So a token of up to 128 characters (the
# longest the tool writes, as in Test-RevealZipHasMaskedValue) is never split,
# and the result equals revealing the whole text at once. The member is replaced
# only when a token was revealed.
function Convert-RevealTextFile
{
    param([Parameter(Mandatory = $true)] [string] $Path, [string] $EscapeMode = 'None')
    $ChunkLength = 65536
    $CarryLength = 127
    # A new name, so no member of the report is ever taken for it.
    $Sibling = $Path + '.' + [guid]::NewGuid().ToString('N') + '.reveal-partial'
    New-RevealOwnerOnlyFile -Path $Sibling
    try
    {
        $Reader = [System.IO.StreamReader]::new($Path, [System.Text.UTF8Encoding]::new($false), $true)
        try
        {
            $Out = [System.IO.FileStream]::new($Sibling, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $Writer = [System.IO.StreamWriter]::new($Out, [System.Text.UTF8Encoding]::new($false)) }
            catch { $Out.Dispose(); throw }
            try
            {
                $Buffer = [char[]]::new($ChunkLength)
                $Pending = ''
                while ($true)
                {
                    # ReadBlock returns less than asked only at the end of the text.
                    $Read = $Reader.ReadBlock($Buffer, 0, $ChunkLength)
                    $AtEnd = $Read -lt $ChunkLength
                    $Text = $Pending + [string]::new($Buffer, 0, $Read)
                    $Cut = $Text.Length
                    if (-not $AtEnd)
                    {
                        $Cut = $Text.Length - $CarryLength
                        # Move the cut back to the start of a token that crosses it.
                        foreach ($M in [regex]::Matches($Text, $TokenPattern))
                        {
                            if ($M.Index -ge $Cut) { break }
                            if ($M.Index + $M.Length -gt $Cut) { $Cut = $M.Index; break }
                        }
                    }
                    if ($Cut -gt 0) { $Writer.Write((Convert-RevealString -Text $Text.Substring(0, $Cut) -EscapeMode $EscapeMode)) }
                    $Pending = $Text.Substring($Cut)
                    if ($AtEnd) { break }
                }
            }
            finally { $Writer.Dispose() }
        }
        finally { $Reader.Dispose() }
        if ($script:FileHits -gt 0) { Copy-RevealSiblingOver -From $Sibling -To $Path }
    }
    finally
    {
        if ([System.IO.File]::Exists($Sibling)) { [System.IO.File]::Delete($Sibling) }
    }
}

# =============================================================================
# Invoke-RdaReveal
#
# The single-report reveal ENGINE, moved here from the former standalone
# Reveal-Obfuscation.ps1 so the whole reveal feature lives in ONE entry script
# (Reveal.ps1) that handles both a single report and a whole multi-subscription
# tree. Takes one obfuscated report zip + its dictionary, rewrites ONLY the
# selected dimensions' tokens back to real values, and re-zips with the same
# structure.
#
# Scope note: this function sets $Replacements and $tokenPattern as LOCALS and
# calls Convert-RevealString, which reads them via PowerShell's parent-scope
# (dynamic) variable lookup, and increments $script:fileHits (the dot-sourcing
# entry script's script scope). That is the same contract the old top-level
# script provided - just nested one function deep - so the helpers behave
# identically. Raises terminating errors via throw (never exit) so a caller /
# Start-Job can catch them.
# =============================================================================
function Invoke-RdaReveal
{
    [CmdletBinding()]
    # $TokenPattern is assigned below and read by Convert-RevealString via
    # PowerShell parent-scope (dynamic) variable lookup, which PSScriptAnalyzer
    # cannot follow across the function boundary - so it false-positives
    # PSUseDeclaredVarsMoreThanAssignments. Suppress that one finding here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'TokenPattern',
        Justification = 'Read cross-scope by Convert-RevealString via parent-scope dynamic lookup.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]   $InputZip,

        [string]   $DictionaryPath,
        [string]   $SearchDirectory = '.',

        [ValidateSet('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')]
        [string[]] $Fields = @('ResourceGroup', 'Subscription'),

        [switch]   $All,

        [string]   $OutputZip,

        # Where the report is expanded while it is revealed (in a new
        # owner-only Reveal_<guid> folder). Defaults to the system temp folder.
        [string]   $TempDirectory
    )

    $ErrorActionPreference = 'Stop'

    # ---- Resolve inputs ----------------------------------------------------
    # Every exact path below goes to -LiteralPath: -Path reads '[' and ']' as a
    # wildcard, so 'report[1]' would match a neighbour named 'report1'.
    # Split-Path -Parent (which takes only -Path) and New-Item -Path work on
    # the text of the path and do not expand wildcards, so they stay as they are.
    # The .NET zip and file calls below resolve a relative path against the
    # process folder, not the PowerShell location, so make both zip paths
    # full paths against the PowerShell location once, here.
    $InputZip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputZip)
    if (-not [string]::IsNullOrEmpty($OutputZip))
    {
        $OutputZip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputZip)
    }

    if (-not (Test-Path -LiteralPath $InputZip -PathType Leaf))
    {
        throw "Input zip not found: $InputZip"
    }

    if ([string]::IsNullOrEmpty($DictionaryPath))
    {
        $DictionaryPath = Get-ChildItem -LiteralPath $SearchDirectory -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($DictionaryPath) -or -not (Test-Path -LiteralPath $DictionaryPath -PathType Leaf))
    {
        throw "No ObfuscationDictionary_*.json found. Pass -DictionaryPath, or run from the folder that holds it."
    }

    if ([string]::IsNullOrEmpty($OutputZip))
    {
        $InDir = Split-Path -Path $InputZip -Parent
        $InBase = [System.IO.Path]::GetFileNameWithoutExtension($InputZip)
        $OutputZip = Join-Path $InDir ($InBase + '_revealed.zip')
    }

    # -All is a convenience for a full reveal: expand to every dimension the
    # dictionary can reverse (overriding -Fields). NOTE this is NOT a perfect
    # undo of -Obfuscate: fields that were nulled or stamped with the lossy
    # 'obfuscated' sentinel are destroyed at obfuscation time. Everything stored
    # in the dictionary comes back.
    if ($All)
    {
        $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
    }

    Write-Host ("Input zip   : {0}" -f $InputZip)
    Write-Host ("Dictionary  : {0}" -f $DictionaryPath)
    Write-Host ("Reveal      : {0}{1}" -f ($Fields -join ', '), $(if ($All) { ' (-All: full reveal)' } else { '' }))
    Write-Host ("Output zip  : {0}" -f $OutputZip)

    # ---- Load dictionary ---------------------------------------------------
    $Dict = Get-Content -LiteralPath $DictionaryPath -Raw | ConvertFrom-Json

    $RgMap = ConvertTo-LookupTable $Dict.ResourceGroupMap
    $SubMap = ConvertTo-LookupTable $Dict.SubscriptionMap
    $SubNameMap = ConvertTo-LookupTable $Dict.SubscriptionNameMap
    $TagMap = ConvertTo-LookupTable $Dict.TagMap
    $IdMap = ConvertTo-LookupTable $Dict.ResourceIdMap
    $NameMap = ConvertTo-LookupTable $Dict.ResourceNameMap
    $FreeTextMap = ConvertTo-LookupTable $Dict.FreeTextMap

    # ---- Build token -> real-value replacement map for selected fields -----
    $Replacements = @{}
    $Skipped = @{}

    if ($Fields -contains 'ResourceGroup')
    {
        foreach ($token in $RgMap.Keys)
        {
            $RgName = Get-RgNameFromResourceId $RgMap[$token]
            if (-not [string]::IsNullOrEmpty($RgName)) { $Replacements[$token] = $RgName }
        }
    }

    if ($Fields -contains 'Subscription')
    {
        foreach ($token in $SubMap.Keys)
        {
            $Real = $null
            if ($SubNameMap.ContainsKey($token) -and -not [string]::IsNullOrEmpty($SubNameMap[$token]))
            {
                $Real = $SubNameMap[$token]
            }
            else
            {
                $Real = Get-SubGuidFromResourceId $SubMap[$token]
                if (-not [string]::IsNullOrEmpty($Real)) { $Skipped['SubscriptionName'] = $true }
            }
            if (-not [string]::IsNullOrEmpty($Real)) { $Replacements[$token] = $Real }
        }
    }

    if ($Fields -contains 'Tag')
    {
        if ($TagMap.Count -eq 0)
        {
            Write-Warning "Tag reveal requested but the dictionary has no TagMap (tags were not obfuscated in this run). Skipping Tag."
        }
        foreach ($token in $TagMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($TagMap[$token])) { $Replacements[$token] = $TagMap[$token] }
        }
    }

    if ($Fields -contains 'ResourceName')
    {
        # ResourceNameMap stores token -> real resource Id; the short name is the
        # last '/'-delimited segment of that Id.
        foreach ($token in $NameMap.Keys)
        {
            $Name = ($NameMap[$token] -split '/')[-1]
            if (-not [string]::IsNullOrEmpty($Name)) { $Replacements[$token] = $Name }
        }
    }

    if ($Fields -contains 'ResourceId')
    {
        # ResourceIdMap stores token -> the full real ARM resource Id. Revealing
        # this also exposes the subscription GUID and resource group name in the
        # path - inherent to revealing the Id and the caller's choice.
        foreach ($token in $IdMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($IdMap[$token])) { $Replacements[$token] = $IdMap[$token] }
        }
    }

    if ($Fields -contains 'FreeText')
    {
        # FreeTextMap stores token -> the real free-form value (Description,
        # FriendlyName, CreatedBy, RoleName, container image, etc.).
        foreach ($token in $FreeTextMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($FreeTextMap[$token])) { $Replacements[$token] = $FreeTextMap[$token] }
        }
    }

    if ($Skipped.ContainsKey('SubscriptionName'))
    {
        Write-Warning "One or more subscriptions had no friendly name in the dictionary (older -Obfuscate run); revealed the subscription GUID instead. Re-run the inventory with a current version to capture SubscriptionNameMap."
    }

    # Token shapes: plain prod_/nonprod_<guid> and type-hinted name tokens
    # (prod_aks_<guid>, etc.) - the regex matches both; the callback only
    # substitutes tokens present in $Replacements, so non-selected dimensions
    # are left masked.
    $TokenPattern = Get-RevealTokenPattern

    if ($Replacements.Count -eq 0)
    {
        # The report of a subscription with no resources carries no masked
        # values, and its dictionary is empty. It has nothing to reveal and is
        # not a failure: write an unchanged copy, so the revealed bundle keeps
        # every subscription. A report that does carry masked values with no
        # mapping for the selected fields is still an error (wrong dictionary
        # or wrong -Fields).
        $HasToken = Test-RevealZipHasMaskedValue -Path $InputZip -TokenPattern $TokenPattern

        if ($HasToken)
        {
            throw "Nothing to reveal: the selected field(s) [$($Fields -join ', ')] produced no token mappings from this dictionary."
        }

        # Same atomic swap as a revealed zip below: copy to .partial.zip, then move.
        Copy-RevealZipUnchanged -InputZip $InputZip -OutputZip $OutputZip
        Write-Host ""
        Write-Host "Nothing to reveal: this report carries no masked values (for example a subscription with no resources). Wrote an unchanged copy." -ForegroundColor Yellow
        Write-Host ("Output: {0}" -f $OutputZip) -ForegroundColor Green
        return
    }

    Write-Host ("Tokens to reveal: {0}" -f $Replacements.Count)

    # ---- Extract, rewrite, re-zip ------------------------------------------

    # The expanded copy gets the real values, so its folder is owner-only
    # before anything is written into it (the system temp folder is shared on
    # Linux). The all-subscriptions run passes a folder inside its owner-only
    # staging folder, and removes it itself if this job is stopped.
    $TempParent = if ([string]::IsNullOrEmpty($TempDirectory)) { [System.IO.Path]::GetTempPath() } else { $TempDirectory }
    $TmpRoot = Join-Path $TempParent ("Reveal_" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null

    try
    {
        try { Set-RevealOwnerOnlyDirectory -Path $TmpRoot }
        catch { throw ("Reveal will not write real names and ids into {0}: {1}" -f $TmpRoot, $_.Exception.Message) }

        # Phase progress (Expanding -> Scanning -> Compressing) so a single
        # report's reveal is not a black box while the opaque extract / compress
        # steps run. Uses the shared Write-RdaProgress when it is
        # loaded (single-report mode via Reveal.ps1, which dot-sources
        # Common.Functions); in the all-subscriptions child job the helper is
        # absent AND the job's output is suppressed, so guard on its presence and
        # no-op there (the wrapper shows a per-folder heartbeat instead).
        $EmitProgress = [bool](Get-Command -Name Write-RdaProgress -ErrorAction SilentlyContinue)
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem 'Expanding archive' -Index 1 -Total 3 }
        # Use System.IO.Compression directly instead of Expand-Archive /
        # Compress-Archive: the cmdlets are markedly slower (a multi-MB report can
        # take minutes to re-zip), whereas ZipFile.ExtractToDirectory and a
        # ZipArchive (Write-RevealZipFromDirectory) do the same work in a fraction of the time and
        # produce the same flat archive layout. $TmpRoot was just created empty,
        # so extraction has nothing to overwrite.
        # The report is checked against the zip limits on the same open
        # archive that is then expanded, so a report that would fill the disk
        # is never expanded.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $InputStream = [System.IO.FileStream]::new($InputZip, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try
        {
            $InputArchive = [System.IO.Compression.ZipArchive]::new($InputStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            try
            {
                Assert-RevealOpenZipWithinLimits -Archive $InputArchive -CompressedLength $InputStream.Length -Path $InputZip -What 'report zip'
                [System.IO.Compression.ZipFileExtensions]::ExtractToDirectory($InputArchive, $TmpRoot)
            }
            finally { $InputArchive.Dispose() }
        }
        finally { $InputStream.Dispose() }

        $TotalHits = 0
        $Files = Get-ChildItem -LiteralPath $TmpRoot -Recurse -File
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem ('Scanning {0} member file(s)' -f @($Files).Count) -Index 2 -Total 3 }
        foreach ($file in $Files)
        {
            $script:FileHits = 0
            $Ext = $file.Extension.ToLowerInvariant()

            # Each member is revealed as a stream into an owner-only sibling
            # file and copied back over the member only after the whole pass
            # succeeded, so a large consumption CSV or a one-line inventory or
            # HTML member is never held in memory at once.
            if ($Ext -eq '.csv')
            {
                Convert-RevealCsvFile -Path $file.FullName
            }
            else
            {
                $EscapeMode = switch ($Ext)
                {
                    '.json' { 'Json' }
                    '.html' { 'Html' }
                    '.htm' { 'Html' }
                    default { 'None' }
                }
                Convert-RevealTextFile -Path $file.FullName -EscapeMode $EscapeMode
            }

            if ($script:FileHits -gt 0)
            {
                $TotalHits += $script:FileHits
                Write-Host ("  {0}: revealed {1} token occurrence(s)" -f $file.Name, $script:FileHits)
            }
        }

        # The selected fields have entries, but none of them was found in the
        # report. If the report still holds masked values and none of them is
        # in any map of this dictionary, the dictionary belongs to another
        # report: fail instead of writing the still masked report as revealed.
        # When some masked value is in the dictionary, it is this report's own
        # dictionary and the selected fields simply have nothing in this
        # report, so the (unchanged) report is written. A report with no masked
        # value at all is written unchanged, as above.
        if ($TotalHits -eq 0 -and
            (Test-RevealZipHasMaskedValue -Path $InputZip -TokenPattern $TokenPattern) -and
            -not (Test-RevealZipHasKnownToken -Path $InputZip -TokenPattern $TokenPattern -KnownTokens (Get-RevealDictionaryTokenSet $Dict)))
        {
            if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -Completed }
            throw "Nothing to reveal: the report holds masked values, but the selected field(s) [$($Fields -join ', ')] have no mapping in this dictionary for any of them. Check that the dictionary belongs to this report."
        }

        # Atomic output: compress to a sibling *.partial.zip, then swap it into
        # place with File.Move(overwrite). A same-volume move is a rename, so a
        # hard kill (SIGKILL / shell timeout) DURING compression can never leave a
        # truncated zip at $OutputZip. This matters for the all-subscriptions
        # reveal (Reveal.ps1), which records each output zip once it is complete,
        # puts in the outer zip only the outputs on its own list for the run
        # (never every *.zip in staging), and on -Resume checks a staged zip
        # against that record: a partial file left at the FINAL name would look
        # like a finished output. The .partial.zip name is never on that list,
        # so only the completed archive ever appears at $OutputZip. A
        # .partial.zip left by a killed run is removed and made new.
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem 'Compressing output' -Index 3 -Total 3 }
        $OutputZipPartial = ($OutputZip -replace '\.zip$', '') + '.partial.zip'
        # The entries sit at the root (the members of $TmpRoot), as
        # ZipFile.CreateFromDirectory with no base folder writes them, matching
        # the previous Compress-Archive -Path "$TmpRoot\*" layout the ingestion
        # server expects. The zip is owner-only from the start (0600, or an
        # owner-only ACL on Windows), and the move keeps that at the final name:
        # it holds the real values.
        Write-RevealZipFromDirectory -SourceDirectory $TmpRoot -Path $OutputZipPartial
        # A revealed zip the ingestion server would refuse is not moved into
        # place.
        try { Assert-RevealZipWithinLimits -Path $OutputZipPartial -What 'revealed zip' }
        catch { Remove-Item -LiteralPath $OutputZipPartial -Force -ErrorAction SilentlyContinue; throw }
        [System.IO.File]::Move($OutputZipPartial, $OutputZip, $true)
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -Completed }

        Write-Host ""
        Write-Host ("Done. Revealed {0} token occurrence(s) across {1} member file(s)." -f $TotalHits, @($Files).Count) -ForegroundColor Green
        Write-Host ("Output: {0}" -f $OutputZip) -ForegroundColor Green
        if ($All)
        {
            Write-Host "Full reveal: all dictionary-backed dimensions restored. Fields nulled at obfuscation time (e.g. Description) or marked 'obfuscated' are lossy and remain so." -ForegroundColor Yellow
        }
        Write-Host "This zip contains the real values you chose to reveal - share only with the intended ingestion party."
    }
    finally
    {
        if (Test-Path -LiteralPath $TmpRoot) { Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
