// SPDX-License-Identifier: AGPL-3.0-only

using System.Buffers.Binary;
using System.Net.Sockets;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace CouchSubs.TvInstall.Android;

/// <summary>ForeignApp: TV'de com.couchsubs.tv kimliğiyle başka imzalı bir uygulama kurulu; kaldırmak için kullanıcı onayı gerekir.</summary>
public enum AndroidInstallError { Unreachable, NotApproved, InstallFailed, ForeignApp }

public sealed class AndroidInstallException(AndroidInstallError error, string? detail = null)
    : Exception(detail is null ? error.ToString() : $"{error}: {detail}")
{
    public AndroidInstallError Error { get; } = error;
}

/// <summary>
/// ADB protokolünün ağ üzerinden kullanılan küçük bir parçası: bağlantı, RSA kimlik doğrulama ve tek seferde bir
/// akış. Google'ın adb aracını dağıtmadan TV'ye uygulama kurmaya yeter. Protokol: AOSP packages/modules/adb
/// (protocol.txt).
/// </summary>
public sealed class AdbConnection : IAsyncDisposable
{
    internal const uint Cnxn = 0x4e584e43, Auth = 0x48545541, Open = 0x4e45504f, Okay = 0x59414b4f,
        Clse = 0x45534c43, Wrte = 0x45545257;
    internal const uint AuthToken = 1, AuthSignature = 2, AuthPublicKey = 3;
    internal const uint Version = 0x01000001;
    private const uint OfferedMaxPayload = 256 * 1024;

    private readonly TcpClient tcp;
    private readonly NetworkStream stream;
    private uint maxPayload = 4096;
    private uint nextLocalId = 1;

    private AdbConnection(TcpClient tcp)
    {
        this.tcp = tcp;
        stream = tcp.GetStream();
    }

    /// <summary>Bağlanır ve TV'nin onayını alır.</summary>
    /// <param name="onApprovalNeeded">TV bu bilgisayarı ilk kez görüyor; ekranda "hata ayıklamaya izin verilsin mi"
    /// sorusu çıktı.</param>
    /// <param name="approvalTimeout">Kullanıcının TV'de onaylaması için tanınan süre.</param>
    public static async Task<AdbConnection> ConnectAsync(string host, int port, RSA key, Action? onApprovalNeeded = null,
        TimeSpan? approvalTimeout = null, CancellationToken cancellationToken = default)
    {
        var tcp = new TcpClient { NoDelay = true };
        try
        {
            using (var connect = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                connect.CancelAfter(TimeSpan.FromSeconds(5));
                await tcp.ConnectAsync(host, port, connect.Token);
            }
        }
        catch (Exception error) when (error is SocketException or OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            tcp.Dispose();
            throw new AndroidInstallException(AndroidInstallError.Unreachable, error.Message);
        }

        var connection = new AdbConnection(tcp);
        try
        {
            await connection.HandshakeAsync(key, onApprovalNeeded, approvalTimeout ?? TimeSpan.FromSeconds(90), cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private async Task HandshakeAsync(RSA key, Action? onApprovalNeeded, TimeSpan approvalTimeout, CancellationToken cancellationToken)
    {
        await WriteAsync(Cnxn, Version, OfferedMaxPayload, Encoding.ASCII.GetBytes("host::\0"), cancellationToken);
        var signed = false;
        var waitingForApproval = false;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        while (true)
        {
            Packet packet;
            try { packet = await ReadAsync(deadline.Token); }
            catch (Exception error) when (error is OperationCanceledException or IOException or EndOfStreamException
                                          && !cancellationToken.IsCancellationRequested)
            {
                // Onay beklenirken bağlantı kapandıysa ya da süre dolduysa kullanıcı izin vermedi.
                throw new AndroidInstallException(waitingForApproval ? AndroidInstallError.NotApproved : AndroidInstallError.Unreachable,
                    error.Message);
            }

            switch (packet.Command)
            {
                case Cnxn:
                    maxPayload = Math.Min(OfferedMaxPayload, packet.Arg1 == 0 ? 4096 : packet.Arg1);
                    return;
                case Auth when packet.Arg0 == AuthToken && !signed:
                    signed = true;
                    await WriteAsync(Auth, AuthSignature, 0, SignToken(key, packet.Data), cancellationToken);
                    break;
                case Auth when packet.Arg0 == AuthToken:
                    // İmza tanınmadı: TV bu anahtarı ilk kez görüyor. Açık anahtarı gönderince TV kullanıcıya sorar.
                    var publicKey = Convert.ToBase64String(EncodePublicKey(key)) + " couchsubs@CouchSubs\0";
                    await WriteAsync(Auth, AuthPublicKey, 0, Encoding.ASCII.GetBytes(publicKey), cancellationToken);
                    waitingForApproval = true;
                    deadline.CancelAfter(approvalTimeout);
                    onApprovalNeeded?.Invoke();
                    break;
                default:
                    throw new AndroidInstallException(AndroidInstallError.Unreachable, $"unexpected packet {packet.Command:x8}");
            }
        }
    }

    /// <summary>
    /// adb, TV'nin gönderdiği 20 baytlık jetonu SHA-1 özeti yerine geçen değer olarak imzalar (RSA_sign NID_sha1):
    /// jeton yeniden özetlenmez.
    /// </summary>
    internal static byte[] SignToken(RSA key, byte[] token) =>
        key.SignHash(token, HashAlgorithmName.SHA1, RSASignaturePadding.Pkcs1);

    /// <summary>Android'in kendi RSA açık anahtar biçimi (system/core/libcrypto_utils android_pubkey.c).</summary>
    internal static byte[] EncodePublicKey(RSA key)
    {
        const int words = 64;
        var parameters = key.ExportParameters(false);
        if (parameters.Modulus is not { Length: words * 4 } modulus || parameters.Exponent is not { } exponentBytes)
            throw new ArgumentException("ADB yalnız 2048 bitlik RSA anahtarını kabul eder.", nameof(key));

        var n = new BigInteger(modulus, isUnsigned: true, isBigEndian: true);
        var r32 = BigInteger.One << 32;
        var n0inv = (uint)(r32 - ModInverse(n % r32, r32));
        var rr = BigInteger.ModPow(BigInteger.One << (words * 32), 2, n);
        uint exponent = 0;
        foreach (var b in exponentBytes) exponent = (exponent << 8) | b;

        var blob = new byte[4 + 4 + words * 4 + words * 4 + 4];
        BinaryPrimitives.WriteUInt32LittleEndian(blob.AsSpan(0), words);
        BinaryPrimitives.WriteUInt32LittleEndian(blob.AsSpan(4), n0inv);
        LittleEndian(n, words * 4).CopyTo(blob, 8);
        LittleEndian(rr, words * 4).CopyTo(blob, 8 + words * 4);
        BinaryPrimitives.WriteUInt32LittleEndian(blob.AsSpan(8 + words * 8), exponent);
        return blob;
    }

    private static byte[] LittleEndian(BigInteger value, int length)
    {
        var bytes = new byte[length];
        value.ToByteArray(isUnsigned: true, isBigEndian: false).AsSpan().CopyTo(bytes);
        return bytes;
    }

    private static BigInteger ModInverse(BigInteger a, BigInteger m)
    {
        BigInteger t = 0, newT = 1, r = m, newR = a;
        while (newR != 0)
        {
            var q = r / newR;
            (t, newT) = (newT, t - q * newT);
            (r, newR) = (newR, r - q * newR);
        }
        return t < 0 ? t + m : t;
    }

    /// <summary>
    /// Bir hizmet açar (ör. <c>shell:…</c>, <c>exec:…</c>), varsa girdiyi gönderir ve hizmet kapanana kadar
    /// çıktıyı toplar.
    /// </summary>
    public async Task<string> RunAsync(string service, Stream? input = null, CancellationToken cancellationToken = default)
    {
        var localId = nextLocalId++;
        await WriteAsync(Open, localId, 0, Encoding.UTF8.GetBytes(service + "\0"), cancellationToken);
        var output = new MemoryStream();
        uint remoteId = 0;
        var closed = false;

        async Task<bool> HandleAsync(Packet packet)
        {
            switch (packet.Command)
            {
                case Okay when packet.Arg1 == localId:
                    remoteId = packet.Arg0;
                    return true;
                case Wrte when packet.Arg1 == localId:
                    output.Write(packet.Data);
                    await WriteAsync(Okay, localId, packet.Arg0, [], cancellationToken);
                    return false;
                case Clse when packet.Arg1 == localId || packet.Arg1 == 0:
                    closed = true;
                    return true;
                default:
                    return false;
            }
        }

        // Hizmetin açıldığını bekle.
        while (!await HandleAsync(await ReadAsync(cancellationToken))) { }
        if (closed && remoteId == 0) throw new AndroidInstallException(AndroidInstallError.InstallFailed, $"{service} açılamadı");

        if (input is not null && !closed)
        {
            var buffer = new byte[maxPayload];
            int read;
            while (!closed && (read = await input.ReadAsync(buffer, cancellationToken)) > 0)
            {
                await WriteAsync(Wrte, localId, remoteId, buffer.AsSpan(0, read).ToArray(), cancellationToken);
                // Bir sonraki parçadan önce TV'nin bu parçayı aldığını bekle; arada gelen çıktıyı da topla.
                while (true)
                {
                    var packet = await ReadAsync(cancellationToken);
                    if (packet.Command == Okay && packet.Arg1 == localId) break;
                    await HandleAsync(packet);
                    if (closed) break;
                }
            }
        }

        while (!closed) await HandleAsync(await ReadAsync(cancellationToken));
        try { await WriteAsync(Clse, localId, remoteId, [], cancellationToken); } catch (IOException) { /* TV kapattı */ }
        return Encoding.UTF8.GetString(output.ToArray());
    }

    internal readonly record struct Packet(uint Command, uint Arg0, uint Arg1, byte[] Data);

    internal static byte[] Encode(uint command, uint arg0, uint arg1, ReadOnlySpan<byte> data)
    {
        var packet = new byte[24 + data.Length];
        var header = packet.AsSpan();
        BinaryPrimitives.WriteUInt32LittleEndian(header, command);
        BinaryPrimitives.WriteUInt32LittleEndian(header[4..], arg0);
        BinaryPrimitives.WriteUInt32LittleEndian(header[8..], arg1);
        BinaryPrimitives.WriteUInt32LittleEndian(header[12..], (uint)data.Length);
        uint sum = 0;
        foreach (var b in data) sum += b;
        BinaryPrimitives.WriteUInt32LittleEndian(header[16..], sum);
        BinaryPrimitives.WriteUInt32LittleEndian(header[20..], command ^ 0xffffffff);
        data.CopyTo(packet.AsSpan(24));
        return packet;
    }

    internal static async Task<Packet> ReadPacketAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[24];
        await stream.ReadExactlyAsync(header, cancellationToken);
        var command = BinaryPrimitives.ReadUInt32LittleEndian(header);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(12));
        if (BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(20)) != (command ^ 0xffffffff) || length > 1024 * 1024)
            throw new IOException("ADB paketi bozuk.");
        var data = new byte[length];
        await stream.ReadExactlyAsync(data, cancellationToken);
        return new Packet(command, BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4)),
            BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8)), data);
    }

    private Task<Packet> ReadAsync(CancellationToken cancellationToken) => ReadPacketAsync(stream, cancellationToken);

    private async Task WriteAsync(uint command, uint arg0, uint arg1, byte[] data, CancellationToken cancellationToken)
    {
        await stream.WriteAsync(Encode(command, arg0, arg1, data), cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    public ValueTask DisposeAsync()
    {
        tcp.Dispose();
        return ValueTask.CompletedTask;
    }
}
