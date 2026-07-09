unit Poseidon.Tests.Security;

// DUnitX unit tests for Poseidon.Net.Security.pas.
// All functions are pure (no I/O), so every branch is reachable without a
// running server.
//
// Coverage goal: 100% of IsMethodAllowed, IsPathSafe, StripCRLF,
//                HasRequestSmuggling, IsIPInCIDR.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TSecurityIsMethodAllowedTests = class
  public
    [Test] procedure EmptyList_AnyMethod_ReturnsTrue;
    [Test] procedure AllowedList_MatchingMethod_ReturnsTrue;
    [Test] procedure AllowedList_MatchingMethod_CaseInsensitive;
    [Test] procedure AllowedList_UnknownMethod_ReturnsFalse;
    [Test] procedure AllowedList_MultipleEntries_MatchesSecond;
    [Test] procedure AllowedList_EmptyString_ReturnsFalse;
  end;

  [TestFixture]
  TSecurityIsPathSafeTests = class
  public
    [Test] procedure RootPath_ReturnsTrue;
    [Test] procedure NormalPath_ReturnsTrue;
    [Test] procedure PathWithQueryString_ReturnsTrue;
    [Test] procedure NulByte_ReturnsFalse;
    [Test] procedure Backslash_ReturnsFalse;
    [Test] procedure PercentEncodedDotDot_ReturnsFalse;
    [Test] procedure PercentEncodedDotDotUpperCase_ReturnsFalse;
    [Test] procedure TraversalInMiddle_ReturnsFalse;
    [Test] procedure TraversalAtEnd_ReturnsFalse;
    [Test] procedure TraversalAtStart_ReturnsFalse;
    [Test] procedure BareDoubleDot_ReturnsFalse;
    [Test] procedure SingleDot_ReturnsTrue;
    [Test] procedure PathWithDotFile_ReturnsTrue;
    [Test] procedure DoubleSlash_StillSafe;
  end;

  [TestFixture]
  TSecurityStripCRLFTests = class
  public
    [Test] procedure NoCRLF_Unchanged;
    [Test] procedure CarriageReturn_Removed;
    [Test] procedure LineFeed_Removed;
    [Test] procedure NulByte_Removed;
    [Test] procedure AllThreeMixed_Removed;
    [Test] procedure EmptyString_ReturnsEmpty;
    [Test] procedure MultipleOccurrences_AllRemoved;
    [Test] procedure OnlySpecialChars_ReturnsEmpty;
  end;

  [TestFixture]
  TSecurityHasRequestSmugglingTests = class
  public
    [Test] procedure BothPresent_ReturnsTrue;
    [Test] procedure OnlyCL_ReturnsFalse;
    [Test] procedure OnlyChunked_ReturnsFalse;
    [Test] procedure NeitherPresent_ReturnsFalse;
  end;

  [TestFixture]
  TSecurityIsIPInCIDRTests = class
  public
    // Happy-path: IPv4 comparisons
    [Test] procedure ExactMatch_Slash32_ReturnsTrue;
    [Test] procedure ExactMatch_Slash32_WrongIP_ReturnsFalse;
    [Test] procedure PrivateRange_Slash8_IPInRange_ReturnsTrue;
    [Test] procedure PrivateRange_Slash8_IPOutsideRange_ReturnsFalse;
    [Test] procedure Slash24_HostInSubnet_ReturnsTrue;
    [Test] procedure Slash24_HostOutsideSubnet_ReturnsFalse;
    [Test] procedure Slash0_MatchesEverything_ReturnsTrue;
    [Test] procedure Slash16_BoundaryIP_ReturnsTrue;
    [Test] procedure Slash1_FirstHalfOfInternet_ReturnsTrue;
    [Test] procedure Slash1_SecondHalfOfInternet_ReturnsFalse;
    // RemoteAddr with port suffix
    [Test] procedure RemoteAddrWithPort_Stripped_ReturnsTrue;
    [Test] procedure RemoteAddrWithPort_Stripped_ReturnsFalse;
    // Fail-open cases (invalid input must not raise and must return True)
    [Test] procedure InvalidCIDR_NoPrefixLen_FailClose;
    [Test] procedure InvalidCIDR_PrefixOutOfRange_FailClose;
    [Test] procedure InvalidCIDR_NotIPv4_FailClose;
    [Test] procedure InvalidRemoteAddr_FailClose;
    [Test] procedure IPv6RemoteAddr_FailClose;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  Poseidon.Net.Security;

// ===========================================================================
// IsMethodAllowed
// ===========================================================================

procedure TSecurityIsMethodAllowedTests.EmptyList_AnyMethod_ReturnsTrue;
begin
  Assert.IsTrue(IsMethodAllowed('GET',    []));
  Assert.IsTrue(IsMethodAllowed('DELETE', []));
  Assert.IsTrue(IsMethodAllowed('TRACE',  []));
end;

procedure TSecurityIsMethodAllowedTests.AllowedList_MatchingMethod_ReturnsTrue;
begin
  Assert.IsTrue(IsMethodAllowed('GET', ['GET', 'POST']));
  Assert.IsTrue(IsMethodAllowed('POST', ['GET', 'POST']));
end;

procedure TSecurityIsMethodAllowedTests.AllowedList_MatchingMethod_CaseInsensitive;
begin
  Assert.IsTrue(IsMethodAllowed('get',  ['GET']));
  Assert.IsTrue(IsMethodAllowed('Get',  ['GET']));
  Assert.IsTrue(IsMethodAllowed('POST', ['post']));
end;

procedure TSecurityIsMethodAllowedTests.AllowedList_UnknownMethod_ReturnsFalse;
begin
  Assert.IsFalse(IsMethodAllowed('DELETE', ['GET', 'POST']));
  Assert.IsFalse(IsMethodAllowed('TRACE',  ['GET', 'POST', 'PUT']));
  Assert.IsFalse(IsMethodAllowed('OPTIONS', ['GET']));
end;

procedure TSecurityIsMethodAllowedTests.AllowedList_MultipleEntries_MatchesSecond;
begin
  Assert.IsTrue(IsMethodAllowed('PUT', ['GET', 'POST', 'PUT', 'DELETE']));
end;

procedure TSecurityIsMethodAllowedTests.AllowedList_EmptyString_ReturnsFalse;
begin
  Assert.IsFalse(IsMethodAllowed('', ['GET', 'POST']));
end;

// ===========================================================================
// IsPathSafe
// ===========================================================================

procedure TSecurityIsPathSafeTests.RootPath_ReturnsTrue;
begin
  Assert.IsTrue(IsPathSafe('/'));
end;

procedure TSecurityIsPathSafeTests.NormalPath_ReturnsTrue;
begin
  Assert.IsTrue(IsPathSafe('/api/v1/users'));
  Assert.IsTrue(IsPathSafe('/health'));
  Assert.IsTrue(IsPathSafe('/static/img/logo.png'));
end;

procedure TSecurityIsPathSafeTests.PathWithQueryString_ReturnsTrue;
begin
  // Query string is separate from path in the parser; but IsPathSafe
  // may receive path-only or path+query depending on caller.
  Assert.IsTrue(IsPathSafe('/search?q=hello'));
end;

procedure TSecurityIsPathSafeTests.NulByte_ReturnsFalse;
begin
  Assert.IsFalse(IsPathSafe('/etc' + #0 + '/passwd'));
  Assert.IsFalse(IsPathSafe(#0));
end;

procedure TSecurityIsPathSafeTests.Backslash_ReturnsFalse;
begin
  Assert.IsFalse(IsPathSafe('/windows\system32'));
  Assert.IsFalse(IsPathSafe('\etc\passwd'));
end;

procedure TSecurityIsPathSafeTests.PercentEncodedDotDot_ReturnsFalse;
begin
  Assert.IsFalse(IsPathSafe('/%2e%2e/etc/passwd'));
  Assert.IsFalse(IsPathSafe('/a/%2e%2e/b'));
end;

procedure TSecurityIsPathSafeTests.PercentEncodedDotDotUpperCase_ReturnsFalse;
begin
  // IsPathSafe lowercases internally; both cases must be rejected
  Assert.IsFalse(IsPathSafe('/%2E%2E/etc/passwd'));
  Assert.IsFalse(IsPathSafe('/%2E%2e/x'));
end;

procedure TSecurityIsPathSafeTests.TraversalInMiddle_ReturnsFalse;
begin
  Assert.IsFalse(IsPathSafe('/a/../b'));
  Assert.IsFalse(IsPathSafe('/x/y/../../etc/passwd'));
end;

procedure TSecurityIsPathSafeTests.TraversalAtEnd_ReturnsFalse;
begin
  Assert.IsFalse(IsPathSafe('/a/b/..'));
  Assert.IsFalse(IsPathSafe('/..'));
end;

procedure TSecurityIsPathSafeTests.TraversalAtStart_ReturnsFalse;
begin
  Assert.IsFalse(IsPathSafe('../etc/passwd'));
  Assert.IsFalse(IsPathSafe('../'));
end;

procedure TSecurityIsPathSafeTests.BareDoubleDot_ReturnsFalse;
begin
  Assert.IsFalse(IsPathSafe('..'));
end;

procedure TSecurityIsPathSafeTests.SingleDot_ReturnsTrue;
begin
  Assert.IsTrue(IsPathSafe('.'));
  Assert.IsTrue(IsPathSafe('/a/.hidden'));
end;

procedure TSecurityIsPathSafeTests.PathWithDotFile_ReturnsTrue;
begin
  // A file named ".gitignore" is not a traversal
  Assert.IsTrue(IsPathSafe('/.gitignore'));
  Assert.IsTrue(IsPathSafe('/api/.well-known/openid-configuration'));
end;

procedure TSecurityIsPathSafeTests.DoubleSlash_StillSafe;
begin
  // Double slashes do not contain ".." — should be safe at protocol level
  Assert.IsTrue(IsPathSafe('//api/v1/users'));
  Assert.IsTrue(IsPathSafe('/a//b'));
end;

// ===========================================================================
// StripCRLF
// ===========================================================================

procedure TSecurityStripCRLFTests.NoCRLF_Unchanged;
begin
  Assert.AreEqual('application/json', StripCRLF('application/json'));
  Assert.AreEqual('https://example.com', StripCRLF('https://example.com'));
end;

procedure TSecurityStripCRLFTests.CarriageReturn_Removed;
begin
  Assert.AreEqual('ab', StripCRLF('a' + #13 + 'b'));
  Assert.AreEqual('ab', StripCRLF(#13 + 'ab'));
  Assert.AreEqual('ab', StripCRLF('ab' + #13));
end;

procedure TSecurityStripCRLFTests.LineFeed_Removed;
begin
  Assert.AreEqual('ab', StripCRLF('a' + #10 + 'b'));
  Assert.AreEqual('hello world', StripCRLF('hello' + #10 + ' world'));
end;

procedure TSecurityStripCRLFTests.NulByte_Removed;
begin
  Assert.AreEqual('ab', StripCRLF('a' + #0 + 'b'));
  Assert.AreEqual('x', StripCRLF(#0 + 'x' + #0));
end;

procedure TSecurityStripCRLFTests.AllThreeMixed_Removed;
var
  LInjected: string;
begin
  // Simulates a header injection attempt: "value\r\nX-Evil: hdr"
  LInjected := 'safe-value' + #13#10 + 'X-Evil: injected';
  Assert.AreEqual('safe-valueX-Evil: injected', StripCRLF(LInjected));
end;

procedure TSecurityStripCRLFTests.EmptyString_ReturnsEmpty;
begin
  Assert.AreEqual('', StripCRLF(''));
end;

procedure TSecurityStripCRLFTests.MultipleOccurrences_AllRemoved;
begin
  Assert.AreEqual('abc', StripCRLF(#13 + 'a' + #10 + 'b' + #0 + 'c'));
end;

procedure TSecurityStripCRLFTests.OnlySpecialChars_ReturnsEmpty;
begin
  Assert.AreEqual('', StripCRLF(#13#10#0#13#10));
end;

// ===========================================================================
// HasRequestSmuggling
// ===========================================================================

procedure TSecurityHasRequestSmugglingTests.BothPresent_ReturnsTrue;
begin
  Assert.IsTrue(HasRequestSmuggling(True, True));
end;

procedure TSecurityHasRequestSmugglingTests.OnlyCL_ReturnsFalse;
begin
  Assert.IsFalse(HasRequestSmuggling(True, False));
end;

procedure TSecurityHasRequestSmugglingTests.OnlyChunked_ReturnsFalse;
begin
  Assert.IsFalse(HasRequestSmuggling(False, True));
end;

procedure TSecurityHasRequestSmugglingTests.NeitherPresent_ReturnsFalse;
begin
  Assert.IsFalse(HasRequestSmuggling(False, False));
end;

// ===========================================================================
// IsIPInCIDR
// ===========================================================================

procedure TSecurityIsIPInCIDRTests.ExactMatch_Slash32_ReturnsTrue;
begin
  Assert.IsTrue(IsIPInCIDR('192.168.1.10', '192.168.1.10/32'));
end;

procedure TSecurityIsIPInCIDRTests.ExactMatch_Slash32_WrongIP_ReturnsFalse;
begin
  Assert.IsFalse(IsIPInCIDR('192.168.1.11', '192.168.1.10/32'));
end;

procedure TSecurityIsIPInCIDRTests.PrivateRange_Slash8_IPInRange_ReturnsTrue;
begin
  Assert.IsTrue(IsIPInCIDR('10.1.2.3',   '10.0.0.0/8'));
  Assert.IsTrue(IsIPInCIDR('10.255.0.1', '10.0.0.0/8'));
  Assert.IsTrue(IsIPInCIDR('10.0.0.0',   '10.0.0.0/8'));
end;

procedure TSecurityIsIPInCIDRTests.PrivateRange_Slash8_IPOutsideRange_ReturnsFalse;
begin
  Assert.IsFalse(IsIPInCIDR('11.0.0.1', '10.0.0.0/8'));
  Assert.IsFalse(IsIPInCIDR('9.9.9.9',  '10.0.0.0/8'));
end;

procedure TSecurityIsIPInCIDRTests.Slash24_HostInSubnet_ReturnsTrue;
begin
  Assert.IsTrue(IsIPInCIDR('192.168.1.1',   '192.168.1.0/24'));
  Assert.IsTrue(IsIPInCIDR('192.168.1.254', '192.168.1.0/24'));
  Assert.IsTrue(IsIPInCIDR('192.168.1.0',   '192.168.1.0/24'));
end;

procedure TSecurityIsIPInCIDRTests.Slash24_HostOutsideSubnet_ReturnsFalse;
begin
  Assert.IsFalse(IsIPInCIDR('192.168.2.1', '192.168.1.0/24'));
  Assert.IsFalse(IsIPInCIDR('192.168.0.1', '192.168.1.0/24'));
end;

procedure TSecurityIsIPInCIDRTests.Slash0_MatchesEverything_ReturnsTrue;
begin
  Assert.IsTrue(IsIPInCIDR('1.2.3.4',     '0.0.0.0/0'));
  Assert.IsTrue(IsIPInCIDR('255.255.255.255', '0.0.0.0/0'));
  Assert.IsTrue(IsIPInCIDR('10.0.0.1',    '0.0.0.0/0'));
end;

procedure TSecurityIsIPInCIDRTests.Slash16_BoundaryIP_ReturnsTrue;
begin
  Assert.IsTrue(IsIPInCIDR('172.16.0.0',   '172.16.0.0/16'));
  Assert.IsTrue(IsIPInCIDR('172.16.255.255', '172.16.0.0/16'));
  Assert.IsFalse(IsIPInCIDR('172.17.0.0',  '172.16.0.0/16'));
end;

procedure TSecurityIsIPInCIDRTests.RemoteAddrWithPort_Stripped_ReturnsTrue;
begin
  // HttpServer stores RemoteAddr as "IP:port"; IsIPInCIDR must strip the port
  Assert.IsTrue(IsIPInCIDR('192.168.1.5:12345', '192.168.1.0/24'));
  Assert.IsTrue(IsIPInCIDR('10.0.0.1:80',       '10.0.0.0/8'));
end;

procedure TSecurityIsIPInCIDRTests.RemoteAddrWithPort_Stripped_ReturnsFalse;
begin
  Assert.IsFalse(IsIPInCIDR('192.168.2.5:12345', '192.168.1.0/24'));
end;

procedure TSecurityIsIPInCIDRTests.InvalidCIDR_NoPrefixLen_FailClose;
begin
  // No '/' → CIDR malformado → fail-close (nunca aceitar sem prefix len)
  Assert.IsFalse(IsIPInCIDR('10.0.0.1', '10.0.0.0'));
end;

procedure TSecurityIsIPInCIDRTests.InvalidCIDR_PrefixOutOfRange_FailClose;
begin
  Assert.IsFalse(IsIPInCIDR('10.0.0.1', '10.0.0.0/33'));
  Assert.IsFalse(IsIPInCIDR('10.0.0.1', '10.0.0.0/-1'));
end;

procedure TSecurityIsIPInCIDRTests.InvalidCIDR_NotIPv4_FailClose;
begin
  // CIDR host that is not dotted-decimal (≠ 4 octets) fails closed (no match),
  // so a malformed/non-IPv4 CIDR never silently matches an address.
  Assert.IsFalse(IsIPInCIDR('10.0.0.1', 'notanip/24'));
end;

procedure TSecurityIsIPInCIDRTests.InvalidRemoteAddr_FailClose;
begin
  // A remote address that is not dotted-decimal (≠ 4 octets) fails closed.
  Assert.IsFalse(IsIPInCIDR('notanip', '10.0.0.0/8'));
end;

procedure TSecurityIsIPInCIDRTests.IPv6RemoteAddr_FailClose;
begin
  // IPv6 addresses do not produce 4 IPv4 octets, so they fail closed against
  // an IPv4 CIDR — prevents an IPv6 peer from bypassing an IPv4 allowlist.
  Assert.IsFalse(IsIPInCIDR('[::1]:8080',   '127.0.0.1/8'));
  Assert.IsFalse(IsIPInCIDR('::1',          '127.0.0.1/8'));
  Assert.IsFalse(IsIPInCIDR('2001:db8::1',  '10.0.0.0/8'));
end;

procedure TSecurityIsIPInCIDRTests.Slash1_FirstHalfOfInternet_ReturnsTrue;
begin
  // /1 mask = $80000000; 0.0.0.0/1 covers 0.x.x.x .. 127.x.x.x
  Assert.IsTrue(IsIPInCIDR('0.0.0.0',    '0.0.0.0/1'));
  Assert.IsTrue(IsIPInCIDR('64.1.2.3',   '0.0.0.0/1'));
  Assert.IsTrue(IsIPInCIDR('127.255.255.255', '0.0.0.0/1'));
end;

procedure TSecurityIsIPInCIDRTests.Slash1_SecondHalfOfInternet_ReturnsFalse;
begin
  // 128.x.x.x is outside 0.0.0.0/1
  Assert.IsFalse(IsIPInCIDR('128.0.0.0', '0.0.0.0/1'));
  Assert.IsFalse(IsIPInCIDR('192.168.1.1', '0.0.0.0/1'));
end;

initialization
  TDUnitX.RegisterTestFixture(TSecurityIsMethodAllowedTests);
  TDUnitX.RegisterTestFixture(TSecurityIsPathSafeTests);
  TDUnitX.RegisterTestFixture(TSecurityStripCRLFTests);
  TDUnitX.RegisterTestFixture(TSecurityHasRequestSmugglingTests);
  TDUnitX.RegisterTestFixture(TSecurityIsIPInCIDRTests);

end.
