#!/usr/bin/env python3
"""Score rewrite benchmark outputs: fact preservation, forbidden invention,
number preservation, style match heuristics."""
import json, os, re, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def normalize(t):
    t = t.lower().replace('ё','е')
    t = re.sub(r'[^\w\s]', '', t, flags=re.UNICODE)
    return re.sub(r'\s+', ' ', t).strip()

def extract_numbers(text):
    """Extract all digit sequences from text."""
    return re.findall(r'\d+', text)

def word_present(word, text_norm):
    """Check if word appears as whole word in normalized text."""
    return bool(re.search(r'\b' + re.escape(word) + r'\b', text_norm))

def score_model(model_name):
    try:
        recs = [json.loads(l) for l in open(f'{ROOT}/results/raw/{model_name}/rewrite.jsonl') if l.strip()]
    except FileNotFoundError:
        return None
    cases = {l['id']: l for l in [json.loads(l) for l in open(f'{ROOT}/corpus/rewrite.jsonl') if l.strip()]}
    
    total = 0
    fact_recall_sum = 0.0
    forbid_violations = 0
    number_preservation_sum = 0.0
    length_ratios = []
    
    for rec in recs:
        cid = rec['id']
        if cid not in cases:
            continue
        case = cases[cid]
        out_norm = normalize(rec['output'])
        inp_norm = normalize(rec['input'])
        
        total += 1
        
        # Fact recall: required_facts present in output
        facts = case.get('required_facts', [])
        if facts:
            hits = 0
            for fact in facts:
                fact_n = normalize(fact)
                # Check if fact appears as substring or words present
                if fact_n in out_norm:
                    hits += 1
                else:
                    # Fuzzy: check if key words present
                    words = fact_n.split()
                    if len(words) >= 2:
                        present = sum(1 for w in words if w in out_norm)
                        if present >= len(words) * 0.7:
                            hits += 0.7
            fact_recall_sum += hits / len(facts)
        
        # Forbidden inventions
        for inv in case.get('forbidden_inventions', []):
            inv_n = normalize(inv)
            if inv_n in out_norm:
                forbid_violations += 1
        
        # Number preservation: input numbers should appear in output
        inp_nums = extract_numbers(inp_norm)
        out_nums = extract_numbers(out_norm)
        if inp_nums:
            preserved = sum(1 for n in inp_nums if n in out_nums)
            number_preservation_sum += preserved / len(inp_nums)
        
        # Length ratio
        if len(inp_norm) > 0:
            length_ratios.append(len(out_norm) / len(inp_norm))
    
    if total == 0:
        return None
    
    return {
        'model': model_name,
        'total_cases': total,
        'fact_recall': round(fact_recall_sum / total, 3),
        'forbidden_violation_rate': round(forbid_violations / total, 3),
        'number_preservation': round(number_preservation_sum / total, 3),
        'avg_length_ratio': round(sum(length_ratios) / len(length_ratios), 3) if length_ratios else 0,
    }

def main():
    models = [d for d in os.listdir(f'{ROOT}/results/raw') if os.path.isdir(f'{ROOT}/results/raw/{d}')]
    results = []
    for m in sorted(models):
        r = score_model(m)
        if r:
            results.append(r)
            print(f"{m:25s} FactRec={r['fact_recall']:.3f} ForbidViol={r['forbidden_violation_rate']:.3f} "
                  f"NumPres={r['number_preservation']:.3f} LenRatio={r['avg_length_ratio']:.3f}")
    
    csv_path = f'{ROOT}/results/rewrite_metrics.csv'
    with open(csv_path, 'w') as f:
        keys = ['model','total_cases','fact_recall','forbidden_violation_rate','number_preservation','avg_length_ratio']
        f.write(','.join(keys) + '\n')
        for r in results:
            f.write(','.join(str(r[k]) for k in keys) + '\n')
    print(f"\nSaved to {csv_path}")

if __name__ == '__main__':
    main()
