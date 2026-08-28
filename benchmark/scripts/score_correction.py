#!/usr/bin/env python3
"""Score correction benchmark outputs: EM, Levenshtein, required recall,
forbidden violation, identity preservation, script normalization P/R/F1."""
import json, os, re, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def normalize(t):
    t = t.lower().replace('ё','е')
    t = re.sub(r'[^\w\s]', '', t, flags=re.UNICODE)
    return re.sub(r'\s+', ' ', t).strip()

def levenshtein(a, b):
    m, n = len(a), len(b)
    dp = list(range(n+1))
    for i in range(1, m+1):
        prev, dp[0] = dp[0], i
        for j in range(1, n+1):
            temp = dp[j]
            dp[j] = min(dp[j]+1, dp[j-1]+1, prev+(a[i-1]!=b[j-1]))
            prev = temp
    return dp[n]

def word_present(word, text_norm):
    """Check if word appears as whole word in normalized text."""
    return bool(re.search(r'\b' + re.escape(word) + r'\b', text_norm))

def score_model(model_name):
    try:
        recs = [json.loads(l) for l in open(f'{ROOT}/results/raw/{model_name}/correction.jsonl') if l.strip()]
    except FileNotFoundError:
        return None
    cases = {l['id']: l for l in [json.loads(l) for l in open(f'{ROOT}/corpus/correction.jsonl') if l.strip()]}
    
    total = 0
    em_count = 0
    lev_sum = 0.0
    req_total = 0
    req_hit = 0
    forbid_total = 0
    forbid_violated = 0
    identity_total = 0
    identity_preserved = 0
    script_tp = 0
    script_fp = 0
    script_fn = 0
    
    details = []
    
    for rec in recs:
        cid = rec['id']
        if cid not in cases:
            continue
        case = cases[cid]
        gold_norm = normalize(case['gold'])
        out_norm = normalize(rec['output'])
        inp_norm = normalize(rec['input'])
        
        total += 1
        
        # Exact Match
        if out_norm == gold_norm:
            em_count += 1
        
        # Levenshtein similarity
        dist = levenshtein(gold_norm, out_norm)
        max_len = max(len(gold_norm), len(out_norm), 1)
        lev_sim = 1.0 - dist / max_len
        lev_sum += lev_sim
        
        # Required changes recall
        for change in case.get('required_changes', []):
            frm, to = change
            frm_n = normalize(frm)
            to_n = normalize(to)
            req_total += 1
            if to_n == '':  # special: just require frm present
                if word_present(frm_n, out_norm):
                    req_hit += 1
            elif frm_n == to_n:  # identity change
                if word_present(to_n, out_norm):
                    req_hit += 1
            else:
                # to must be present AND frm must be absent (if it was an error)
                if word_present(to_n, out_norm) and not word_present(frm_n, out_norm):
                    req_hit += 1
                elif word_present(to_n, out_norm):  # to present but frm also present (partial)
                    req_hit += 0.5
        
        # Forbidden changes
        for change in case.get('forbidden_changes', []):
            frm, to = change
            frm_n = normalize(frm)
            to_n = normalize(to)
            forbid_total += 1
            if to_n == '':  # frm must be present
                if not word_present(frm_n, out_norm):
                    forbid_violated += 1
            else:  # frm must stay, to must NOT appear
                if word_present(to_n, out_norm):
                    forbid_violated += 1
        
        # Identity preservation (for identity cases)
        if case['category'] == 'identity':
            identity_total += 1
            if lev_sim >= 0.95:
                identity_preserved += 1
        
        # Script normalization
        if case['category'] == 'script_normalization':
            for change in case.get('required_changes', []):
                frm, to = change
                frm_n = normalize(frm)
                to_n = normalize(to)
                if word_present(to_n, out_norm):
                    script_tp += 1
                else:
                    script_fn += 1
        if case['category'] == 'hard_negative':
            for change in case.get('forbidden_changes', []):
                frm, to = change
                to_n = normalize(to)
                if word_present(to_n, out_norm):
                    script_fp += 1
        
        details.append({
            'id': cid, 'category': case['category'],
            'exact_match': out_norm == gold_norm,
            'lev_sim': round(lev_sim, 3),
            'output_preview': rec['output'][:80]
        })
    
    if total == 0:
        return None
    
    script_precision = script_tp / max(script_tp + script_fp, 1)
    script_recall = script_tp / max(script_tp + script_fn, 1)
    script_f1 = 2 * script_precision * script_recall / max(script_precision + script_recall, 0.001)
    
    return {
        'model': model_name,
        'total_cases': total,
        'exact_match': round(em_count / total, 3),
        'levenshtein_sim': round(lev_sum / total, 3),
        'required_recall': round(req_hit / max(req_total, 1), 3),
        'forbidden_violation_rate': round(forbid_violated / max(forbid_total, 1), 3),
        'identity_preservation': round(identity_preserved / max(identity_total, 1), 3),
        'script_precision': round(script_precision, 3),
        'script_recall': round(script_recall, 3),
        'script_f1': round(script_f1, 3),
        'details': details
    }

def main():
    models = [d for d in os.listdir(f'{ROOT}/results/raw') if os.path.isdir(f'{ROOT}/results/raw/{d}')]
    results = []
    for m in sorted(models):
        r = score_model(m)
        if r:
            results.append(r)
            print(f"{m:25s} EM={r['exact_match']:.3f} Lev={r['levenshtein_sim']:.3f} "
                  f"ReqRec={r['required_recall']:.3f} ForbidViol={r['forbidden_violation_rate']:.3f} "
                  f"Ident={r['identity_preservation']:.3f} ScriptF1={r['script_f1']:.3f}")
    
    # Save to CSV
    csv_path = f'{ROOT}/results/correction_metrics.csv'
    with open(csv_path, 'w') as f:
        keys = ['model','total_cases','exact_match','levenshtein_sim','required_recall',
                'forbidden_violation_rate','identity_preservation','script_precision','script_recall','script_f1']
        f.write(','.join(keys) + '\n')
        for r in results:
            f.write(','.join(str(r[k]) for k in keys) + '\n')
    print(f"\nSaved to {csv_path}")

if __name__ == '__main__':
    main()
