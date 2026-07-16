import { useCallback, useEffect, useMemo, useState } from 'react';
import QRCode from 'qrcode';
import type { ReceiptListItem, ReceiptReview, ReceiptStatus, ReconciliationRow } from '@challanse/contracts';
import {
  API_BASE_URL,
  PUBLIC_API_URL,
  ApiError,
  acceptMembershipInvitation,
  createEnrollmentCode,
  createMembershipInvitation,
  downloadAuditExport,
  getActiveSiteId,
  getAdminConfiguration,
  getAdminSummary,
  getReviewerContext,
  importPurchaseOrders,
  listReceipts,
  listReconciliation,
  reviewReceipt,
  revokeDevice,
  saveOrganizationQuota,
  saveSiteConfiguration,
  saveVendorConfiguration,
  setActiveSiteId,
  type AdminConfiguration,
  type AdminSummary,
  type ReviewerContext,
} from './api';

const filters: Array<{ value: ReceiptStatus; label: string }> = [
  { value: 'NEEDS_REVIEW', label: 'Needs review' },
  { value: 'VERIFIED', label: 'Verified' },
  { value: 'REJECTED', label: 'Rejected' },
];

function formatTime(unix: number) {
  return new Intl.DateTimeFormat('en-IN', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(unix * 1000));
}

function ReceiptCard({ receipt, onSaved }: { receipt: ReceiptListItem; onSaved: () => void }) {
  const [challanNumber, setChallanNumber] = useState(receipt.challanNumber);
  const [poNumber, setPoNumber] = useState(receipt.poNumber);
  const [materialCode, setMaterialCode] = useState(receipt.materialCode);
  const [description, setDescription] = useState(receipt.materialDescription);
  const [quantity, setQuantity] = useState(String(receipt.verifiedQuantity ?? receipt.capturedQuantity));
  const [unit, setUnit] = useState(receipt.unit || 'UNIT');
  const [notes, setNotes] = useState(receipt.notes);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');

  const submit = async (action: ReceiptReview['action']) => {
    setBusy(true);
    setMessage('');
    try {
      await reviewReceipt(receipt.id, {
        action,
        version: receipt.version,
        challanNumber,
        poNumber,
        materialCode,
        materialDescription: description,
        verifiedQuantity: Number(quantity),
        unit,
        notes,
      });
      onSaved();
    } catch (caught) {
      setMessage(caught instanceof ApiError && caught.status === 409 ? 'This receipt changed. Refreshing the inbox.' : caught instanceof Error ? caught.message : 'Review failed.');
      if (caught instanceof ApiError && caught.status === 409) onSaved();
    } finally {
      setBusy(false);
    }
  };

  const editable = receipt.status === 'NEEDS_REVIEW';
  return (
    <article className="receipt-card">
      <div className="receipt-media">
        <img src={`${API_BASE_URL}${receipt.imageUrl}`} alt={`Challan from ${receipt.vendorName}`} loading="lazy" />
        <span className={`status status-${receipt.status.toLowerCase()}`}>{receipt.status.replace('_', ' ')}</span>
      </div>
      <div className="receipt-context">
        <div><strong>{receipt.vendorName}</strong><span>{formatTime(receipt.capturedAtUnix)}</span></div>
        <div><strong>{receipt.capturedQuantity}</strong><span>Site-captured quantity</span></div>
      </div>
      <details className="ocr-evidence" open={receipt.status === 'NEEDS_REVIEW'}>
        <summary>OCR evidence {receipt.ocrConfidence === null ? '' : `· ${receipt.ocrConfidence.toFixed(1)}%`}</summary>
        <pre>{JSON.stringify(receipt.rawOcrJson, null, 2)}</pre>
      </details>
      <form className="review-form" onSubmit={(event) => { event.preventDefault(); void submit('VERIFY'); }}>
        <label>Challan number<input value={challanNumber} onChange={(event) => setChallanNumber(event.target.value)} disabled={!editable || busy} /></label>
        <label>PO number<input required value={poNumber} onChange={(event) => setPoNumber(event.target.value.toUpperCase())} disabled={!editable || busy} /></label>
        <label>Material code<input required value={materialCode} onChange={(event) => setMaterialCode(event.target.value.toUpperCase())} disabled={!editable || busy} /></label>
        <label className="wide">Material description<input required value={description} onChange={(event) => setDescription(event.target.value)} disabled={!editable || busy} /></label>
        <label>Verified quantity<input required type="number" min="0.001" step="any" value={quantity} onChange={(event) => setQuantity(event.target.value)} disabled={!editable || busy} /></label>
        <label>Unit<input required value={unit} onChange={(event) => setUnit(event.target.value.toUpperCase())} disabled={!editable || busy} /></label>
        <label className="wide">Notes<textarea value={notes} onChange={(event) => setNotes(event.target.value)} disabled={!editable || busy} /></label>
        {message ? <p className="form-message" role="alert">{message}</p> : null}
        {editable ? <div className="review-actions"><button type="button" className="button secondary" onClick={() => void submit('REJECT')} disabled={busy || !description || !quantity || !unit}>Reject</button><button className="button primary" disabled={busy || !poNumber || !materialCode || !description || !quantity || !unit}>{busy ? 'Saving…' : 'Verify receipt'}</button></div> : null}
      </form>
    </article>
  );
}

function DeltaView() {
  const [rows, setRows] = useState<ReconciliationRow[]>([]);
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(true);

  const load = useCallback(async () => {
    setBusy(true);
    setMessage('');
    try { setRows((await listReconciliation()).rows); }
    catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Reconciliation is unavailable.'); }
    finally { setBusy(false); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const upload = async (file: File) => {
    setBusy(true);
    setMessage('');
    try {
      const result = await importPurchaseOrders(await file.text());
      setMessage(result.duplicate ? 'This purchase-order file was already imported.' : `${result.row_count} purchase-order rows imported.`);
      await load();
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Purchase-order import failed.'); }
    finally { setBusy(false); }
  };

  return <section className="delta-view">
    <div className="delta-actions"><div><h1>Delta view</h1><p>Verified site receipts compared with the latest Tally purchase-order import.</p></div><label className="button primary file-button">Import Tally CSV<input type="file" accept=".csv,text/csv" onChange={(event) => { const file = event.target.files?.[0]; if (file) void upload(file); }} /></label></div>
    {message ? <p className="form-message" role="status">{message}</p> : null}
    {busy && rows.length === 0 ? <div className="empty">Loading reconciliation…</div> : null}
    {!busy && rows.length === 0 ? <div className="empty"><strong>No purchase orders imported.</strong><span>Import the approved Tally CSV to begin reconciliation.</span></div> : null}
    {rows.length ? <div className="table-scroll"><table><thead><tr><th>PO</th><th>Material</th><th>Unit</th><th>PO quantity</th><th>Site received</th><th>Result</th></tr></thead><tbody>{rows.map((row) => <tr className={row.isOver ? 'delta-over' : ''} key={`${row.poNumber}:${row.materialCode}:${row.unit}`}><td>{row.poNumber}</td><td>{row.materialCode}</td><td>{row.unit}</td><td>{row.poQuantity}</td><td>{row.siteReceived}</td><td>{row.isOver ? 'Over PO' : 'Within PO'}</td></tr>)}</tbody></table></div> : null}
  </section>;
}

function AdminPanel({ onClose, role }: { onClose: () => void; role: string }) {
  const [summary, setSummary] = useState<AdminSummary | null>(null);
  const [configuration, setConfiguration] = useState<AdminConfiguration | null>(null);
  const [deviceName, setDeviceName] = useState('Gate device');
  const [enrollment, setEnrollment] = useState<{ code: string; qr: string } | null>(null);
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const [siteName, setSiteName] = useState('');
  const [wifiSsids, setWifiSsids] = useState('');
  const [siteDailyLimit, setSiteDailyLimit] = useState('1000');
  const [vendorId, setVendorId] = useState('');
  const [vendorName, setVendorName] = useState('');
  const [vendorInitials, setVendorInitials] = useState('');
  const [vendorColor, setVendorColor] = useState('#0F766E');
  const [deviceLimit, setDeviceLimit] = useState('100');
  const [deviceRequestLimit, setDeviceRequestLimit] = useState('120');
  const [organizationDailyLimit, setOrganizationDailyLimit] = useState('1000');
  const [storageLimitGb, setStorageLimitGb] = useState('5');
  const [memberEmail, setMemberEmail] = useState('');
  const [memberName, setMemberName] = useState('');
  const [memberRole, setMemberRole] = useState<'ORG_ADMIN' | 'SITE_ADMIN' | 'CONTROLLER' | 'REVIEWER' | 'AUDITOR'>('REVIEWER');
  const [membershipInvitation, setMembershipInvitation] = useState('');

  const load = useCallback(async () => {
    try {
      const [nextSummary, nextConfiguration] = await Promise.all([getAdminSummary(), getAdminConfiguration()]);
      setSummary(nextSummary);
      setConfiguration(nextConfiguration);
      setDeviceLimit(String(nextConfiguration.organization.deviceLimit));
      setDeviceRequestLimit(String(nextConfiguration.organization.deviceRequestLimitPerMinute));
      setOrganizationDailyLimit(String(nextConfiguration.organization.dailyReceiptLimit));
      setStorageLimitGb(String(nextConfiguration.organization.storageByteLimit / 1_000_000_000));
      const selectedSite = nextConfiguration.sites.find((site) => site.id === getActiveSiteId());
      if (selectedSite) {
        setSiteName(selectedSite.name);
        setWifiSsids(selectedSite.allowedWifiSsids.join('\n'));
        setSiteDailyLimit(String(selectedSite.dailyReceiptLimit));
      }
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Unable to load administration.'); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const createCode = async () => {
    setMessage('');
    try {
      const result = await createEnrollmentCode(deviceName);
      const payload = `challanse://enroll?api=${encodeURIComponent(PUBLIC_API_URL)}&code=${encodeURIComponent(result.enrollmentCode)}`;
      setEnrollment({ code: result.enrollmentCode, qr: await QRCode.toDataURL(payload, { width: 260, margin: 1, errorCorrectionLevel: 'M' }) });
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Unable to create enrollment code.'); }
  };

  const storagePercent = summary ? Math.round((summary.site.storedImageBytes / summary.site.storageByteLimit) * 100) : 0;
  const selectedSite = configuration?.sites.find((site) => site.id === getActiveSiteId());
  const saveSite = async () => {
    if (!selectedSite) return;
    setBusy(true); setMessage('');
    try {
      await saveSiteConfiguration({
        siteId: selectedSite.id,
        name: siteName.trim(),
        allowedWifiSsids: wifiSsids.split('\n').map((value) => value.trim()).filter(Boolean),
        dailyReceiptLimit: Number(siteDailyLimit),
        imageByteLimit: selectedSite.imageByteLimit,
        active: selectedSite.active,
      });
      setMessage('Site settings saved. Devices receive the new version at bootstrap.');
      await load();
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Site settings could not be saved.'); }
    finally { setBusy(false); }
  };
  const addVendor = async () => {
    setBusy(true); setMessage('');
    try {
      await saveVendorConfiguration({ vendorId: vendorId.trim(), name: vendorName.trim(), initials: vendorInitials.trim(), color: vendorColor, displayOrder: configuration?.vendors.filter((vendor) => vendor.siteId === getActiveSiteId()).length || 0, active: true });
      setVendorId(''); setVendorName(''); setVendorInitials('');
      setMessage('Vendor saved and queued for the next device bootstrap.');
      await load();
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Vendor could not be saved.'); }
    finally { setBusy(false); }
  };
  const saveQuota = async () => {
    if (!configuration) return;
    setBusy(true); setMessage('');
    try {
      await saveOrganizationQuota({
        deviceLimit: Number(deviceLimit),
        deviceRequestLimitPerMinute: Number(deviceRequestLimit),
        dailyReceiptLimit: Number(organizationDailyLimit),
        storageByteLimit: Math.round(Number(storageLimitGb) * 1_000_000_000),
      });
      setMessage('Organization limits confirmed.');
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Organization limits could not be saved.'); }
    finally { setBusy(false); }
  };
  const inviteMember = async () => {
    setBusy(true); setMessage(''); setMembershipInvitation('');
    try {
      const result = await createMembershipInvitation({
        email: memberEmail.trim(),
        displayName: memberName.trim(),
        role: memberRole,
        siteIds: memberRole === 'ORG_ADMIN' ? [] : [getActiveSiteId()],
      });
      setMembershipInvitation(result.invitationCode);
      setMessage('Invitation created. Share this one-time code securely; it expires in 24 hours.');
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Membership invitation could not be created.'); }
    finally { setBusy(false); }
  };
  return <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
    <section className="admin-panel" role="dialog" aria-modal="true" aria-labelledby="admin-title" onMouseDown={(event) => event.stopPropagation()}>
      <header><div><p>Site administration</p><h2 id="admin-title">{summary?.site.name || 'ChallanSe pilot'}</h2></div><button className="icon-button" onClick={onClose} aria-label="Close administration">×</button></header>
      {message ? <p className="form-message" role="alert">{message}</p> : null}
      {summary ? <div className={`quota ${storagePercent >= 70 ? 'warning' : ''}`}><span>Receipt image storage</span><strong>{storagePercent}%</strong><div><i style={{ width: `${Math.min(storagePercent, 100)}%` }} /></div></div> : null}
      {summary ? <div className="provider-state" aria-label="Provider availability"><strong>OCR active</strong><span>GST, credit, WhatsApp, and Slack disabled</span></div> : null}
      {selectedSite ? <div className="admin-section"><h3>Site controls</h3><label>Site name<input value={siteName} onChange={(event) => setSiteName(event.target.value)} maxLength={160} /></label><label>Approved Wi-Fi, one name per line<textarea value={wifiSsids} onChange={(event) => setWifiSsids(event.target.value)} rows={3} /></label><label>Daily receipt limit<input type="number" min="1" max="100000" value={siteDailyLimit} onChange={(event) => setSiteDailyLimit(event.target.value)} /></label><button className="button primary" disabled={busy || !siteName.trim() || Number(siteDailyLimit) < 1} onClick={() => void saveSite()}>Save site</button></div> : null}
      {configuration ? <div className="admin-section"><h3>Vendors</h3><div className="vendor-list">{configuration.vendors.filter((vendor) => vendor.siteId === getActiveSiteId()).map((vendor) => <span key={vendor.id}><i style={{ background: vendor.color }} />{vendor.name}</span>)}</div><div className="admin-grid"><label>Vendor code<input value={vendorId} onChange={(event) => setVendorId(event.target.value)} placeholder="vendor-code" /></label><label>Name<input value={vendorName} onChange={(event) => setVendorName(event.target.value)} /></label><label>Initials<input value={vendorInitials} maxLength={3} onChange={(event) => setVendorInitials(event.target.value.toUpperCase())} /></label><label>Color<input type="color" value={vendorColor} onChange={(event) => setVendorColor(event.target.value)} /></label></div><button className="button secondary" disabled={busy || !vendorId.trim() || !vendorName.trim() || !vendorInitials.trim()} onClick={() => void addVendor()}>Add vendor</button></div> : null}
      {configuration && role === 'ORG_ADMIN' ? <div className="admin-section compact-section"><h3>Organization limits</h3><div className="admin-grid"><label>Devices<input type="number" min="1" max="1000" value={deviceLimit} onChange={(event) => setDeviceLimit(event.target.value)} /></label><label>Device requests/min<input type="number" min="30" max="600" value={deviceRequestLimit} onChange={(event) => setDeviceRequestLimit(event.target.value)} /></label><label>Receipts/day<input type="number" min="1" max="100000" value={organizationDailyLimit} onChange={(event) => setOrganizationDailyLimit(event.target.value)} /></label><label>Storage (GB)<input type="number" min="0.1" max="10000" step="0.1" value={storageLimitGb} onChange={(event) => setStorageLimitGb(event.target.value)} /></label></div><button className="button secondary" disabled={busy || Number(deviceLimit) < 1 || Number(deviceRequestLimit) < 30 || Number(deviceRequestLimit) > 600 || Number(organizationDailyLimit) < 1 || Number(storageLimitGb) < 0.1} onClick={() => void saveQuota()}>Save limits</button></div> : null}
      {configuration && role === 'ORG_ADMIN' ? <div className="admin-section"><h3>Team access</h3><div className="member-list">{configuration.memberships.map((member) => <span key={member.userId}><strong>{member.displayName || member.email}</strong><small>{member.role} · {member.active ? 'Active' : 'Inactive'}</small></span>)}</div><div className="admin-grid"><label>Email<input type="email" value={memberEmail} onChange={(event) => setMemberEmail(event.target.value)} /></label><label>Name<input value={memberName} maxLength={160} onChange={(event) => setMemberName(event.target.value)} /></label><label>Role<select value={memberRole} onChange={(event) => setMemberRole(event.target.value as typeof memberRole)}><option value="REVIEWER">Reviewer</option><option value="CONTROLLER">Controller</option><option value="AUDITOR">Auditor</option><option value="SITE_ADMIN">Site admin</option><option value="ORG_ADMIN">Organization admin</option></select></label></div><button className="button secondary" disabled={busy || !memberEmail.trim()} onClick={() => void inviteMember()}>Create invite code</button>{membershipInvitation ? <div className="invite-code"><strong>{membershipInvitation}</strong><span>Single use · 24 hours</span></div> : null}</div> : null}
      <div className="audit-actions"><h3>Audit export</h3><p>Download the immutable site audit index for client records.</p><button className="button secondary" onClick={() => void downloadAuditExport('csv')}>Download CSV</button><button className="button secondary" onClick={() => void downloadAuditExport('json')}>Download JSON</button></div>
      <div className="enrollment"><h3>Enroll a site device</h3><p>Create a one-time QR code. It expires in 10 minutes.</p><label>Device name<input value={deviceName} onChange={(event) => setDeviceName(event.target.value)} maxLength={80} /></label><button className="button primary" onClick={() => void createCode()} disabled={!deviceName.trim()}>Create enrollment QR</button>{enrollment ? <div className="qr-result"><img src={enrollment.qr} alt={`Enrollment QR for code ${enrollment.code}`} /><strong>{enrollment.code}</strong><span>Scan once in the ChallanSe Android app</span></div> : null}</div>
      <div className="devices"><h3>Enrolled devices</h3>{summary?.devices.length ? summary.devices.map((device) => <div className="device-row" key={device.id}><div><strong>{device.name}</strong><span>{device.active ? `Last seen ${device.lastSeenAt || 'not yet'}` : 'Revoked'}</span></div>{device.active ? <button className="text-button danger" onClick={async () => { await revokeDevice(device.id); await load(); }}>Revoke</button> : null}</div>) : <p>No devices enrolled.</p>}</div>
    </section>
  </div>;
}

export default function App() {
  const [view, setView] = useState<'INBOX' | 'DELTA'>('INBOX');
  const [status, setStatus] = useState<ReceiptStatus>('NEEDS_REVIEW');
  const [receipts, setReceipts] = useState<ReceiptListItem[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [busy, setBusy] = useState(true);
  const [message, setMessage] = useState('');
  const [adminOpen, setAdminOpen] = useState(false);
  const [context, setContext] = useState<ReviewerContext | null>(null);
  const [activeSite, setActiveSite] = useState('');
  const [invitationCode, setInvitationCode] = useState('');

  useEffect(() => {
    void getReviewerContext().then((result) => {
      setContext(result);
      const remembered = getActiveSiteId();
      const selected = result.sites.some((site) => site.siteId === remembered)
        ? remembered
        : result.sites.length === 1 ? result.sites[0].siteId : '';
      setActiveSiteId(selected);
      setActiveSite(selected);
    }).catch((caught) => {
      setMessage(caught instanceof Error ? caught.message : 'Reviewer access could not be loaded.');
      setBusy(false);
    });
  }, []);

  const load = useCallback(async (append = false) => {
    if (!activeSite) { setBusy(false); return; }
    setBusy(true);
    setMessage('');
    try {
      const result = await listReceipts(status, append ? nextCursor || undefined : undefined);
      setReceipts((current) => append ? [...current, ...result.receipts] : result.receipts);
      setNextCursor(result.nextCursor);
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : 'The inbox could not be loaded.');
    } finally { setBusy(false); }
  }, [activeSite, nextCursor, status]);

  useEffect(() => { if (activeSite) void load(false); }, [activeSite, status]);
  const title = useMemo(() => filters.find((filter) => filter.value === status)?.label || 'Receipts', [status]);
  const activeAccess = context?.sites.find((site) => site.siteId === activeSite);
  const canAdmin = activeAccess?.role === 'ORG_ADMIN' || activeAccess?.role === 'SITE_ADMIN';

  const acceptInvitation = async () => {
    setBusy(true); setMessage('');
    try {
      await acceptMembershipInvitation(invitationCode.trim());
      window.location.reload();
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : 'Invitation could not be accepted.');
      setBusy(false);
    }
  };

  return <div className="app-shell">
    <header className="topbar"><a href="https://challanse.constrovet.com" className="brand"><span aria-hidden="true">▦</span>ChallanSe</a>{context && context.sites.length > 1 ? <label className="site-switch">Site<select value={activeSite} onChange={(event) => { setActiveSiteId(event.target.value); setActiveSite(event.target.value); }}><option value="">Choose site</option>{context.sites.map((site) => <option key={site.siteId} value={site.siteId}>{site.siteName}</option>)}</select></label> : null}<nav className="view-switch" aria-label="Reviewer views"><button className={view === 'INBOX' ? 'active' : ''} onClick={() => setView('INBOX')} disabled={!activeSite}>Inbox</button><button className={view === 'DELTA' ? 'active' : ''} onClick={() => setView('DELTA')} disabled={!activeSite}>Delta</button></nav>{canAdmin ? <button className="button secondary compact" onClick={() => setAdminOpen(true)}>Site setup</button> : null}</header>
    <main>
      {!context ? <section className="membership-accept"><h1>Join your ChallanSe team</h1><p>Enter the one-time code supplied by your organization administrator.</p><label>Invitation code<input value={invitationCode} onChange={(event) => setInvitationCode(event.target.value)} autoComplete="one-time-code" /></label><button className="button primary" disabled={busy || invitationCode.trim().length < 16} onClick={() => void acceptInvitation()}>Accept invitation</button></section> : null}
      {context && !activeSite ? <div className="notice" role="status"><strong>Choose a site to continue.</strong><span>Your access is limited to the sites listed above.</span></div> : null}
      {view === 'DELTA' ? <DeltaView /> : <>
      <section className="inbox-header"><div><h1>{title}</h1><p>Review the image, correct the receipt details, and make one clear decision.</p></div><button className="icon-button refresh" onClick={() => void load(false)} aria-label="Refresh inbox">↻</button></section>
      <nav className="filters" aria-label="Receipt status">{filters.map((filter) => <button key={filter.value} className={status === filter.value ? 'active' : ''} onClick={() => setStatus(filter.value)}>{filter.label}</button>)}</nav>
      {message ? <div className="notice error" role="alert">{message}<button onClick={() => void load(false)}>Retry</button></div> : null}
      {busy && receipts.length === 0 ? <div className="empty">Loading receipts…</div> : null}
      {!busy && receipts.length === 0 && !message ? <div className="empty"><strong>Nothing waiting here.</strong><span>New site receipts will appear automatically.</span></div> : null}
      <div className="receipt-list">{receipts.map((receipt) => <ReceiptCard key={receipt.id} receipt={receipt} onSaved={() => void load(false)} />)}</div>
      {nextCursor ? <button className="button secondary load-more" onClick={() => void load(true)} disabled={busy}>Load more</button> : null}
      </>}
    </main>
    {adminOpen && activeAccess ? <AdminPanel role={activeAccess.role} onClose={() => setAdminOpen(false)} /> : null}
  </div>;
}
