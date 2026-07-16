import { useCallback, useEffect, useMemo, useState } from 'react';
import QRCode from 'qrcode';
import type { ReceiptListItem, ReceiptReview, ReceiptStatus, ReconciliationRow } from '@challanse/contracts';
import {
  API_BASE_URL,
  PUBLIC_API_URL,
  ApiError,
  createEnrollmentCode,
  getAdminSummary,
  importPurchaseOrders,
  listReceipts,
  listReconciliation,
  reviewReceipt,
  revokeDevice,
  type AdminSummary,
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

function AdminPanel({ onClose }: { onClose: () => void }) {
  const [summary, setSummary] = useState<AdminSummary | null>(null);
  const [deviceName, setDeviceName] = useState('Gate device');
  const [enrollment, setEnrollment] = useState<{ code: string; qr: string } | null>(null);
  const [message, setMessage] = useState('');

  const load = useCallback(async () => {
    try { setSummary(await getAdminSummary()); } catch (caught) { setMessage(caught instanceof Error ? caught.message : 'Unable to load administration.'); }
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
  return <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
    <section className="admin-panel" role="dialog" aria-modal="true" aria-labelledby="admin-title" onMouseDown={(event) => event.stopPropagation()}>
      <header><div><p>Site administration</p><h2 id="admin-title">{summary?.site.name || 'ChallanSe pilot'}</h2></div><button className="icon-button" onClick={onClose} aria-label="Close administration">×</button></header>
      {message ? <p className="form-message" role="alert">{message}</p> : null}
      {summary ? <div className={`quota ${storagePercent >= 70 ? 'warning' : ''}`}><span>Receipt image storage</span><strong>{storagePercent}%</strong><div><i style={{ width: `${Math.min(storagePercent, 100)}%` }} /></div></div> : null}
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

  const load = useCallback(async (append = false) => {
    setBusy(true);
    setMessage('');
    try {
      const result = await listReceipts(status, append ? nextCursor || undefined : undefined);
      setReceipts((current) => append ? [...current, ...result.receipts] : result.receipts);
      setNextCursor(result.nextCursor);
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : 'The inbox could not be loaded.');
    } finally { setBusy(false); }
  }, [nextCursor, status]);

  useEffect(() => { void load(false); }, [status]);
  const title = useMemo(() => filters.find((filter) => filter.value === status)?.label || 'Receipts', [status]);

  return <div className="app-shell">
    <header className="topbar"><a href="https://challanse.constrovet.com" className="brand"><span aria-hidden="true">▦</span>ChallanSe</a><nav className="view-switch" aria-label="Reviewer views"><button className={view === 'INBOX' ? 'active' : ''} onClick={() => setView('INBOX')}>Inbox</button><button className={view === 'DELTA' ? 'active' : ''} onClick={() => setView('DELTA')}>Delta</button></nav><button className="button secondary compact" onClick={() => setAdminOpen(true)}>Site setup</button></header>
    <main>
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
    {adminOpen ? <AdminPanel onClose={() => setAdminOpen(false)} /> : null}
  </div>;
}
