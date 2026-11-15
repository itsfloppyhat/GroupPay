'use strict';
const $ = id => document.getElementById(id);
// Fragment credentials never reach HTTP access logs or referrer headers.
let token = location.hash.slice(1);
try {
  if (token) sessionStorage.setItem('group-pay-guest', token);
  else token = sessionStorage.getItem('group-pay-guest') || '';
} catch (_) { /* Restricted storage still allows this visit to complete. */ }
if (location.hash) history.replaceState(null, '', '/guest');
let record;
const money = cents => new Intl.NumberFormat('en-US', {style:'currency',currency:'USD'}).format(cents / 100);
function tipValue() {
  const value = $('tip').value.trim();
  if (!/^\d{1,8}(\.\d{1,2})?$/.test(value)) return null;
  const [whole, fraction = ''] = value.split('.');
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  const p = record.portion;
  return cents <= Math.max(p.foodCents, p.tipCents) && p.foodCents + p.taxCents + p.feeCents + cents <= 10000000 ? cents : null;
}
function updateTotal() {
  const tip = tipValue(), p = record.portion;
  $('total').textContent = tip === null ? '—' : money(p.foodCents + p.taxCents + p.feeCents + tip);
  $('tip-summary').textContent = tip === null ? 'Check amount' : money(tip);
  $('approve').disabled = tip === null;
  $('approve').textContent = tip === null ? 'Enter a valid tip' : `Approve my ${money(p.foodCents + p.taxCents + p.feeCents + tip)}`;
  document.querySelectorAll('[data-tip]').forEach(button => button.setAttribute('aria-pressed', String(tip === Math.floor((p.foodCents * Number(button.dataset.tip) + 50) / 100))));
}
async function api(method = 'GET', body) {
  const response = await fetch('/guest-api/portion', {method, headers:{Authorization:`Guest ${token}`, ...(body ? {'Content-Type':'application/json'} : {})}, body:body ? JSON.stringify(body) : undefined, cache:'no-store', credentials:'omit', redirect:'error'});
  if (!response.ok) {
    if (response.status === 404) throw new Error('This invitation isn’t available. Ask the organizer for a new link.');
    if (response.status === 409) throw new Error('This portion was already approved. Refresh to see its status.');
    throw new Error('We couldn’t save or load your portion. Check your connection and try again.');
  }
  return response.json();
}
function render() {
  const p = record.portion;
  $('bill-title').textContent = p.title;
  $('greeting').textContent = `Your portion, ${p.name}`;
  for (const key of ['food','tax','fee']) $(key).textContent = money(p[key+'Cents']);
  $('tip').value = ((record.approvedTipCents ?? p.tipCents) / 100).toFixed(2);
  updateTotal();
  const approved = record.approvedTipCents !== null;
  $('approval').hidden = approved || record.closed || record.expired;
  $('status').textContent = record.closed ? 'This invitation is closed. Check with your organizer for the split’s status.' : approved ? 'You’re all set! Your approval is saved. Your organizer will see it when their app refreshes.' : record.expired ? 'This link has expired. Ask your organizer for a new invitation.' : '';
  $('portion').hidden = false;
}
async function load() {
  $('error').hidden = true; $('retry').hidden = true;
  try { if (!token) throw new Error('Open your personal invitation link to view your portion.'); record = await api(); render(); }
  catch (error) { $('error').textContent = error.message; $('error').hidden = false; $('retry').hidden = !token; }
  finally { $('loading').hidden = true; }
}
$('tip').addEventListener('input', updateTotal);
document.querySelectorAll('[data-tip]').forEach(button => button.addEventListener('click', () => {
  $('tip').value = (Math.floor((record.portion.foodCents * Number(button.dataset.tip) + 50) / 100) / 100).toFixed(2); updateTotal();
}));
$('approval').addEventListener('submit', async event => {
  event.preventDefault(); const tip = tipValue(); if (tip === null) return;
  $('approve').disabled = true; $('tip-controls').disabled = true; $('error').hidden = true;
  try { record = await api('POST', {tipCents:tip}); render(); $('status').focus(); }
  catch(error) { $('error').textContent = error.message; $('error').hidden = false; $('retry').hidden = false; }
  finally { $('approve').disabled = false; $('tip-controls').disabled = false; }
});
$('retry').addEventListener('click', load);
load();
